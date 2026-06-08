# WePark — Field Testing Log

Running log of fixes/errors Kevin observes while using the app on real hardware (TestFlight 1.0+).
Newest items at top. Each item: status, area, what was seen, proposed fix, and where it lands.

**Status legend:** 🔴 open · 🟡 spec'd / in progress · 🟢 fixed (PR merged) · ⚪️ won't-fix / deferred

---

## Session 2026-06-08

### FT-6 🔵 Customizable ASP reminder timing — multiple reminders + "night before" (FEATURE)
- **Area:** `NotificationScheduler` + Settings UI. iOS-only.
- **Request (Kevin, 2026-06-08):** First ASP notification landed well ("looks great") but fires at a
  fixed 1h before. Wants to customize *when* reminders fire and have MULTIPLE per restriction —
  e.g. 1h before AND 15 min before, plus **a reminder the night before** he has to move the car.
- **Current state:** single notification per pin at fixed `notificationLeadTimeSeconds = 1*3600`
  (Constants.swift:60). BUT architecture is already forward-compatible: ID scheme
  `wepark.pin.<carID>.r<ruleIndex>` and `notificationID(for:ruleIndex:)` are parameterized; W6 spec
  reserved `r1` for "future two-notification design." So this is an extension, not a rebuild.
- **Design questions (surfaced to Kevin):** global-Settings vs per-pin config; preset lead-times vs
  fully custom; "night before" semantics (recommend: fixed clock time the prior evening, default
  8:00 PM ET, skip if already past); iOS 64-pending-notification cap (non-issue at ~4-5/pin).
- **Lands in:** iOS only (`NotificationScheduler.swift`, `Constants.swift`, `SettingsView.swift`,
  maybe `ParkedCar` if per-pin). Tech-lead spec after Kevin's decisions. No backend/schema change.

---

## Session 2026-06-06 (cont.)

### FT-5 🟡 Map snaps back to previous view while panning (free-browse mode) — MERGED, on-device confirm pending
- **Resolution (2026-06-07):** Fix implemented per `docs/ft5-region-sync-interaction-guard-spec.md`
  (isUserInteracting guard in `MapViewRepresentable.updateUIView`). QA PASS, zero findings
  (`docs/qa/ft5-region-sync-qa.md`). Cold clean build + sim launch verified by orchestrator.
  Unit tests lock the guard logic (4 RegionSyncGuardTests cases). **MERGED to main via PR #47
  (squash 6dbde45).** Behavioral pan-test (10s no snap-back) to be confirmed by Kevin on the next
  TestFlight build (reaches device via TF2) — flip to 🟢 after he verifies on-device.
- **Area:** `MapViewRepresentable.updateUIView` non-Drive-Mode region sync. Core map UX.
- **Observed:** While scrolling/panning the map (not in Drive Mode), it frequently snaps back to
  the prior view. Not every time — happens often. (Kevin has video examples; agent can't view video.)
- **Root cause (high confidence):** `updateUIView` (MapViewRepresentable.swift:615-621) re-applies
  the SwiftUI `region` binding to the map via `setRegion` whenever the live map center differs from
  the binding by >0.0001° (~11 m). But `regionDidChangeAnimated` (which writes the binding back via
  `handleRegionChanged`, ContentView.swift:1020-1025) only fires when the pan GESTURE SETTLES — so
  mid-drag the binding is stale. Any unrelated SwiftUI re-render during the drag (8s community-pin
  poll, ASP banner clock tick, location update, overlay refresh) re-invokes `updateUIView`, which
  sees live≠binding and calls `setRegion(staleBinding)` → yanks the camera back mid-pan.
  → "frequent but not every time" = only when a background re-render coincides with an active drag.
  Drive Mode is unaffected (gated out via `shouldSyncRegionToBinding`, uses `syncDriveRegion`).
- **Proposed fix:** Track user interaction — set `isUserInteracting=true` on `regionWillChange`
  (user gesture) and clear on `regionDidChange`; in `updateUIView`, suppress the binding→map
  `setRegion` while interacting. Programmatic recenters (recenter button ContentView:1488,
  animateToCoordinate :1524) still apply because they're not user-driven. Add a
  `RegionSyncGuardTests` case to lock it.
- **Process:** Touches MapViewRepresentable/updateUIView chain → tech-lead spec + ios-engineer in
  worktree + qa-verifier + LIVE-UI SMOKE GATE required (per #31-regression discipline).
- **Lands in:** iOS only (`MapViewRepresentable.swift`), no backend/schema change.

---

## Session 2026-06-06 — first real-device play session

### FT-1 🔴 Sweeper / agent pin timing is too long (5 min is stale)
- **Area:** Tier 3 community pins (enforcement agent + street sweeper) — display/decay logic.
- **Observed:** Pins linger ~5 min before going away. For a moving parking attendant or street
  sweeper, 5 min is already stale — they move fast, so the pin misleads after ~1 min.
- **Proposed fix:** Shorten the active/fresh window dramatically for *mobile* pin types
  (enforcement, sweeper). Likely a much shorter expiry (e.g. ~1–2 min fresh, then fade or show a
  "last seen Xm ago" stale icon rather than a confident live marker). Static types (no-parking,
  ASP) keep their current lifetime.
- **Open question:** exact fresh-window per type? And do we *expire* vs. *visually demote to stale*?
- **Lands in:** likely backend (`expires_at` / decay) + iOS marker styling. Needs tech-lead spec —
  touches the pin lifetime contract both display and reporting depend on.

### FT-2 🔴 No way to redact/delete your own pin (accidental report)
- **Area:** Tier 3 reporting — author controls.
- **Observed:** After dropping a report there's no way to undo/delete it if it was accidental.
- **Proposed fix:** Let the pin author delete (or retract) their own pin. Anonymous-auth means we
  identify the author by their anon `user_id` (the reporter). Tapping your own pin should offer a
  "Delete / I was wrong" action. Needs RLS policy allowing delete where `reporter_id = auth.uid()`.
- **Lands in:** backend (RLS + RPC) + iOS pin-detail UI. Tech-lead spec.

### FT-3 🔴 Up/down-vote on pins should be easy (may already partially work)
- **Area:** Tier 3 reactions (confirm/dispute).
- **Observed:** Wants clear, easy up/down-vote on pins. Confirm/dispute exists (3 disputes
  auto-resolve) but the affordance may not read as "vote."
- **Finding (2026-06-06):** Voting IS already implemented in `PinDetailSheet.swift:296-320` —
  "Still there?" = confirm + extend TTL (upvote), "Gone" = dispute (downvote, 3 auto-resolves).
  So the mechanism is live; this is a *labeling/affordance* item, not missing functionality. The
  buttons just don't read as "up/down vote."
- **Proposed fix:** Designer/UX polish — make the confirm/dispute affordance read more obviously as
  a vote (clearer iconography, maybe a count). No backend change needed.
- **Lands in:** iOS pin-detail UI (`PinDetailSheet.swift`). Designer pass. Likely lowest priority
  of the three since it already functions.
- **Update (2026-06-06):** Confirmed voting can't be self-tested — the A1 own-pin guard
  (`PinDetailSheet.swift:335-358`) disables BOTH buttons on a pin you authored (by design: no
  self-voting). Since Kevin is the only tester, every live pin is "his own" → buttons always grey.
  Voting is verifiable only against a pin authored by someone else (or `author_id = null`, seeded).
  This also strengthens FT-2: own pins should show a Delete action where others' pins show votes —
  today an own pin shows neither, which reads as "dead." FT-2 closes that gap.

### FT-4 🟢 "Still there?" greyed out on a pre-TF1 test pin — voting appeared broken (RESOLVED)
- **Area:** Tier 3 reactions × test data.
- **Observed (2026-06-06):** Kevin tried to vote on a pin placed before TF1; the vote "didn't
  work." Confirmed symptom: the "Still there?" button was **greyed out / un-tappable**.
- **Root cause (NOT a prod bug):** `PinDetailSheet.swift:346-353` `isStillHereDisabled` disables
  confirm-extend when `expiresAt > now + 115min` (within 5 min of the 2h TTL cap — correct for real
  pins). The two forever-test pins have `expires_at` past **2030**, so the guard always fires and
  the button is permanently disabled on them. Real pins (expiry ≤ 2h out) behave correctly.
- **Fix:** Delete the two forever-test pins (handoff-noted). SQL below. No code change needed —
  the disable logic is correct for legitimately-fresh pins.
  ```sql
  delete from public.pins where source='crowd' and expires_at > '2030-01-01';
  ```
- **Status:** 🟢 RESOLVED 2026-06-06 — Kevin ran the DELETE in the Supabase dashboard; both test
  pins removed (confirmed 2 rows: `enforcement_active` + `sweeper_passed`, both `expires_at`=2099).
  Real-pin voting now behaves normally. No code change required.
- **Latent note:** the disable rule is intentional, but worth confirming with designer that a
  near-cap pin showing a disabled "Still there?" with no explanation isn't confusing in the wild.

---
