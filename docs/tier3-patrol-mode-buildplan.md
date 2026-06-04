# Tier 3 / Patrol Mode — Build Plan and Sub-PR Decomposition

**Status:** Planning spec. Date: 2026-06-04.
**Owner:** Tech Lead (this doc), Kevin (OQ table approval), @ios-engineer + @backend-data (execution).
**Anchor docs:** `docs/community-1.0-direction.md` §4–6.3, `docs/community-1.0-buildplan.md` §3 and §5.
**Foundational state:** `docs/typed-pin-schema-spec.md` + `supabase/02-pins-schema.sql` LIVE in production (applied 2026-06-04). `docs/tier1-pin-display-spec.md` LIVE in production (PR #37, `9219c2e`, 300/0 tests).
**Supersedes:** nothing (first Tier 3 planning doc). `docs/community-1.0-buildplan.md` §3 (Tier 3 section) is the upstream, not superseded — this doc decomposes it.

---

## Open Questions for Kevin — Surface These First

| # | Question | Options | Recommendation |
|---|---|---|---|
| OQ-T3-1 | **Tier 3 pin types in the first patrol-mode cut: all 4 or start with 2?** | (a) All 4: `enforcement_active`, `sweeper_passed`, `broken_meter`, `open_spot`. (b) Start with `enforcement_active` + `sweeper_passed` only; defer `broken_meter` + `open_spot`. | **(b) Start with 2.** `enforcement_active` + `sweeper_passed` are the highest-density use cases (happen daily; both are ephemeral with 30-min TTL). `broken_meter` is durable-until-resolved and shares Tier 2's reporting pattern more than Tier 3's decay pattern — its value depends less on density. `open_spot` requires its own schema migration (`open_spot` enum value does not exist yet) AND a separate `claim` mechanic — it is the highest-risk type. Both deferred types get their own subsequent sub-PRs. |
| OQ-T3-2 | **Report-entry UX: long-press map vs. "Report" FAB vs. both?** | (a) Long-press the map to initiate a report (consistent with W5 pin-drop UX — same gesture). (b) A "Report" FAB (floating action button) in patrol mode's UI chrome. (c) Both — long-press AND a FAB; they converge on the same report flow. | **(a) Long-press only, first cut.** W5 already owns the long-press gesture (`ParkPinService`, 0.4s); the implementation must be patrol-mode-aware (when patrol mode is active AND the user long-presses, the crowd-report flow triggers instead of the park-pin flow). A FAB can be added in a TF2 polish pass once the flow is validated. Both-simultaneously (option c) doubles the surface area and the QA burden for the first cut. |
| OQ-T3-3 | **Decay visual approach: opacity fade or time-since badge?** | (a) Opacity fade: pin marker opacity decreases linearly from `expiresAt - 30min` (fresh, opacity 1.0) to `expiresAt` (about to expire, opacity 0.2). (b) Time-since badge only: pin marker stays fully opaque; a small "Xm ago" label on the callout signals staleness. (c) Both: fade + label. | **(b) Time-since badge only, first cut.** Opacity fade on `MKAnnotationView` requires a timer loop that redraws annotations periodically — ongoing UIKit complexity for every visible pin. The time-since badge is a `UILabel` update on tap-to-callout only (lazy), lower implementation risk, and communicates the same trust signal. `@designer` should validate in a subsequent pass. Fade can be added in a TF2 polish PR once the trust loop is proven. |
| OQ-T3-4 | **Relevance-gated push + Drive Mode callout: in this cut or fast-follow?** | (a) Include "Enforcement near your car" push notification and "Enforcement 2 blocks ahead" Drive Mode chip in this Tier 3 cut. (b) Defer to a TF2 fast-follow; Tier 3 first cut is map-only (marker + confirm/dispute). | **(b) Defer push + Drive Mode callout.** The push path requires `NotificationScheduler` extension + parked-car proximity check — a separate concern from the reporting + reactions loop. The Drive Mode callout requires `DrivingContextService` extension + route-corridor pin query. Both add risk to a PR that is already introducing anonymous auth + write path + decay display. Land the map marker + reactions first; add relevance-gated alerts in two focused follow-up specs (documented in §7 below). |
| OQ-T3-5 | **`open_spot` schema migration timing: before Tier 3 sub-PR #1, or after enforcement is proven?** | (a) Migrate `open_spot` into `pin_type` enum immediately (in sub-PR #1's backend work). (b) Defer the migration until `open_spot` reporting UI is specced and ready to build. | **(b) Defer the migration.** The `ALTER TYPE public.pin_type ADD VALUE 'open_spot'` migration is a DDL that cannot be rolled back within a transaction (`ADD VALUE` is not transactional in Postgres). Applying it before the feature is ready creates a gap where the enum value exists but no RLS, iOS model, or UI handles it. Land the migration in the sub-PR that first writes `open_spot` pins (sub-PR #4 in the sequence below). This also avoids the iOS `PinType` enum going out of sync with the DB mid-build. |

---

## 1. The One New Hard Primitive Tier 3 Introduces

`docs/community-1.0-buildplan.md §3` names this correctly: "decay + 'still there?' confirm." But there is a primitive that sits logically before decay can work: **the identity + write path**.

The decay mechanic (`extend_pin_expiry` RPC) already exists in production. The `votes` table and its `unique(pin_id, user_id)` constraint already exist. The trigger that updates `confirm_count` / `dispute_count` already exists. The schema infra IS built.

What does NOT exist yet:

1. **Supabase Anonymous Auth wiring in iOS.** No call to `signInAnonymously()` has been made. No JWT is attached to any Supabase request. The `pins_insert_crowd` RLS policy requires `auth.uid() is not null` — so every crowd-pin insert will fail with `401 Unauthorized` until anonymous auth is live.

2. **The write path itself.** `CommunityPinService` is read-only today. There is no `insertPin(...)` or `upsertVote(...)` call anywhere in the iOS codebase.

3. **The patrol-mode UI surface.** W8.5e–i in the HANDOFF.md roadmap is "patrol mode" — the Drive Mode variant for someone cruising for parking without a destination. The reporting flow hangs off this UI.

Therefore: **sub-PR #1 is anonymous auth + the write path (insert + vote)**. Everything else in Tier 3 unblocks from it.

---

## 2. Sub-PR Sequence

```
[sub-PR #1]  Anonymous auth + write path (iOS auth wiring + insert + vote RPCs)
                    │
          ┌─────────┴──────────┐
  [sub-PR #2]                [sub-PR #3 — parallel]
  Patrol mode UI surface     Decay display layer
  (W8.5e–i reporting flow)   (time-since badge, expires_at countdown,
  @ios-engineer              confirm-count badge)
          │                  @ios-engineer
          └─────────┬─────────┘
                    │
           [sub-PR #4]
           `open_spot` — schema migration + iOS enum + dedicated
           claim mechanic + ultra-short decay
           (SOHO/LES beachhead only; OQ-T3-5 migration lands here)
                    │
           [sub-PR #5]
           Relevance-gated push (pin near parked car)
           @ios-engineer + @backend-data
                    │
           [sub-PR #6]
           Drive Mode community callout (pin on route)
           @ios-engineer
```

Sub-PRs #2 and #3 are **parallel** — they touch disjoint files. #2 owns the patrol mode entry point, long-press gesture, and report sheet. #3 owns the decay visual layer applied to already-visible pins. Neither can start until #1 is merged (the `SupabaseAuthService` they both call must exist).

Sub-PR #4 (open_spot) serializes after #2 and #3 are complete because the UI pattern (report sheet + decay display) is already live and `open_spot` just adds a new pin type to them.

Sub-PRs #5 and #6 are Tier 3.5 — fast-follow specs that are out of scope for the initial Tier 3 cut per OQ-T3-4.

---

## 3. Mapping to W8.5e–i Slots

Per `HANDOFF.md` roadmap, the W8.5 sequence after W8.5d is: drive-test → W8.5c-follow voice calibration → patrol mode (W8.5e–i) → W8 TF1. "Patrol mode W8.5e–i" in the master spec is now formally decomposed as:

| W8.5 slot | Content | Sub-PR |
|---|---|---|
| **W8.5e** | Anonymous auth wiring + iOS write path + vote path | sub-PR #1 |
| **W8.5f** | Patrol mode UI surface: mode entry, long-press report flow, report sheet | sub-PR #2 |
| **W8.5g** | Decay display layer: time-since badge, confirm-count badge, expires_at countdown | sub-PR #3 |
| **W8.5h** | `open_spot` schema migration + iOS model extension + claim mechanic | sub-PR #4 |
| **W8.5i** | Relevance-gated push + Drive Mode callout (fast-follow; out of initial TF1 scope) | sub-PRs #5–#6 |

W8.5e (sub-PR #1) unblocks W8.5f and W8.5g running in parallel. The combined W8.5e–g is the minimum viable Tier 3 that lights up SOHO/LES enforcement reporting.

---

## 4. Parallel Work-Stream Table

| Stream | Owner | Spec doc | Unblocked by | Parallel with |
|---|---|---|---|---|
| **#1a — Anonymous auth** | @ios-engineer | `tier3-auth-and-reactions-spec.md` | Kevin OQ-table approval | #1b (disjoint files) |
| **#1b — Backend: `open_spot` enum migration planning** | @backend-data | `tier3-auth-and-reactions-spec.md` (notes section) | Kevin OQ-T3-5 | #1a (disjoint) |
| **#2 — Patrol mode UI** | @ios-engineer | `tier3-patrol-mode-ui-spec.md` (to write) | sub-PR #1 merged | #3 (disjoint files) |
| **#3 — Decay display** | @ios-engineer | `tier3-decay-display-spec.md` (to write) | sub-PR #1 merged | #2 (disjoint files) |
| **#4 — open_spot** | @ios-engineer + @backend-data | `tier3-open-spot-spec.md` (to write) | sub-PRs #2 + #3 merged | Nothing |
| **#5 — Push alerts** | @ios-engineer | `tier3-push-alerts-spec.md` (to write) | sub-PR #4 merged | #6 |
| **#6 — Drive Mode callout** | @ios-engineer | `tier3-drive-callout-spec.md` (to write) | sub-PR #4 merged | #5 |

---

## 5. Live-UI Smoke Gate (mandatory for sub-PRs #2 and #3)

Per `HANDOFF.md` and `docs/tier1-pin-display-spec.md §5`, any PR touching `ContentView.swift` or `MapViewRepresentable.swift` requires a pre-merge simulator screenshot verifying the overlay layer (ASP banner, toolbar, bottom cards) is intact. Sub-PRs #2 and #3 both touch these files. The gate is not optional.

---

## 6. Acceptance Criteria (Build Plan Level)

**Tier 3 minimum viable (sub-PRs #1 + #2 + #3 done) when:**

- [ ] **AC-T3.0** A fresh-install iOS user is silently assigned an anonymous Supabase auth identity with no login screen, email, or prompt.
- [ ] **AC-T3.1** (from `community-1.0-buildplan.md §7`) A patrol-mode user in SOHO/LES can report `enforcement_active` with optional sub-tag. The pin appears on all other users' maps within 5s (Realtime).
- [ ] **AC-T3.2** An `enforcement_active` pin's `expires_at` starts at 30 minutes. A "Still there?" tap by a second user calls `extend_pin_expiry` and extends it by 15 minutes (capped at 2h).
- [ ] **AC-T3.3** An `enforcement_active` pin with no confirms after 30 minutes disappears from the map (client-side expiry filter in `CommunityPinService.clientSideFilter`).
- [ ] **AC-T3.4** A "Gone" tap by a user inserts a `dispute` vote; if `dispute_count >= 3`, the pin is removed from all clients' maps within 5s (via `resolved_at` being set server-side, picked up by Realtime).
- [ ] **AC-T3.5** The map marker for an `enforcement_active` pin shows a "Xm ago" time-since label in the callout, reflecting `now() - createdAt` in minutes.
- [ ] **AC-T3.6** A user cannot vote on their own pin (RLS enforced server-side or iOS-side guard, confirmed by test).
- [ ] **AC-T3.7** All architecture invariants from `HANDOFF.md` + `docs/tier1-pin-display-spec.md §5` hold: no mutation inside `updateUIView`; no new `setRegion` calls; `RegionSyncGuardTests` pass; no `Calendar.current` use; no `headlessWindow` guard.

**`open_spot` beachhead (sub-PR #4 done) when:**
- [ ] **AC-T3.8** `ALTER TYPE public.pin_type ADD VALUE 'open_spot'` is live in production.
- [ ] **AC-T3.9** iOS `PinType` enum has `.openSpot = "open_spot"` case.
- [ ] **AC-T3.10** `open_spot` pin `expires_at` defaults to `now() + interval '3 minutes'` at insert.
- [ ] **AC-T3.11** A "Heading there" tap sets a `claim` state (stored locally) that dims the pin marker for the claiming user, reducing racing.
- [ ] **AC-T3.12** SOHO/LES zone filter is enforced: a user outside the SOHO/LES bounding box cannot report an `open_spot` pin (iOS-side guard + server-side `zone_id` validation in the insert RPC).

---

## 7. Out-of-Scope Follow-Ups

**Relevance-gated push (pin near parked car).** When a new `enforcement_active` pin is inserted within 50m of `parkedCar.coordinate`, a local push fires: "Enforcement near your car on [block] — consider moving it." This requires extending `CommunityPinService`'s Realtime subscription to compare incoming pins against `ParkPinService.currentCar.coordinate`. The seam exists (`ParkPinService.pinDropped` publisher). Out of Tier 3 initial cut per OQ-T3-4. Spec target: `docs/tier3-push-alerts-spec.md`. Tag: `@ios-engineer`.

**Drive Mode community callout.** When Drive Mode is active and a `enforcement_active` or `sweeper_passed` pin is within 200m of the user's current location on the active route, a chip in `DriveModeBottomCard` fires: "Enforcement 2 blocks ahead." The seam exists (`DrivingContextService` + `CommunityPinService.visiblePins`). Out of initial cut per OQ-T3-4. Spec target: `docs/tier3-drive-callout-spec.md`. Tag: `@ios-engineer`.

**Tier 2 sign correction + block note.** These durable crowd types (the non-ephemeral reputation-driven pins) are not Tier 3. They serialize after Tier 3's reputation primitives are live (an anonymous author_id is sufficient for reputation keying, so Tier 2 can technically start after sub-PR #1). Spec target: `docs/tier2-sign-correction-spec.md`. Not blocked by any sub-PR in this plan.

**Sign in with Apple (identity upgrade).** Per `community-1.0-direction.md §6.3`, anonymous auth can be upgraded to Apple Sign-In later without losing history. This is NOT in Tier 3 initial scope. The anonymous UUID is the reputation key for TF1 and TF2. The upgrade flow is a post-TF2 prompt triggered at a moment of value (e.g., "keep your contributions across devices"). Spec target: `docs/tier3-identity-upgrade-spec.md`. Tag: `@ios-engineer`.

**`broken_meter` reporting.** Durable-until-resolved, low density requirement — shares more with Tier 2's reporting pattern than Tier 3's decay pattern. Can be added to the patrol-mode report sheet as an additional pin type after sub-PR #2 is proven. One paragraph spec addition; not a full sub-PR.

**Beachhead distribution (SOHO/LES seeding).** Per `community-1.0-buildplan.md §3`, the beachhead requires 10–20 active reporters. This is a Kevin-owned distribution task (sticker program + zone-chat invite). Not a code sub-PR. Signal metric: ≥3 confirms on an `enforcement_active` pin within 5 minutes of report = the density threshold is met. Kevin defines the distribution go/no-go.
