# WePark — Field Testing Log

Running log of fixes/errors Kevin observes while using the app on real hardware (TestFlight 1.0+).
Newest items at top. Each item: status, area, what was seen, proposed fix, and where it lands.

**Status legend:** 🔴 open · 🟡 spec'd / in progress · 🟢 fixed (PR merged) · ⚪️ won't-fix / deferred

---

## Map rebuild (native MapKit) — `docs/map-rebuild-native-mapkit-spec.md`

- **Phase 1 (browse liberation) 🟢 MERGED #54, build 1.0(5), VERIFIED ON-DEVICE (Kevin):** "much cleaner,
  just like Apple Maps, streets rendering." Enabled rotate/tilt; MapKit owns the browse camera (removed
  the updateUIView setRegion push → snap-back class gone); programmatic centering preserved via
  coordinatorActions.setRegion. Drive Mode untouched.
- **Phase 2 (native drive follow) 🟢 MERGED #55, build 1.0(6):** native userTrackingMode=.follow +
  FT-7 course heading (not compass, orthogonal). Pan→`didChange:mode:`→Recenter button; Recenter
  re-engages .follow + restores 45° pitch + FT-8 zoom. Removed syncDriveRegion/shouldSyncDriveRegion/
  driveFollowEnabled/onDrivePanDetected/recenterDriveMap. QA PASS-WITH-NOTES (`docs/qa/map-phase2-qa.md`),
  446/0. ⏳ Kevin's on-device DRIVE-TEST is the irreducible gate (native .follow can't run headless).
- **Tech-debt cleanup (deferred, low-pri) — batch into one housekeeping PR:**
  - Swift strict-concurrency/Sendability warnings: NotificationScheduler (UNUserNotificationCenter
    completion-handler closures) + RouteService (nowET / bundleTokenProvider main-actor isolation).
    Warnings only, compile+run fine, not Swift 6 mode.
  - FT-7 followup: wire `selectDriveHeadingSource` into the production path (currently inline-equivalent).
  - FT-9 followup: replace the "paid until" string-match gate with an `isMeteredActivePaidHours` boolean.
  - Phase 2 stale comments: `isUserInteracting` doc + `syncDriveHeading` comments still name deleted
    symbols (shouldSyncDriveRegion/onDrivePanDetected/driveFollowEnabled). Comment-only.
  - Missing test: assert `recenterMap` (ContentView) actually calls `coordinatorActions.setRegion?`.

## TF2 Round 1 — on-device testing of build 1.0(2) (2026-06-08 evening)

Findings from Kevin testing the TF2 build (FT-1/5/6/7/8/9/10) on his iPhone. Labeled TF2-N.

### TF2-2 🟢 Live-map pan still snaps back mid-drag (async race) — FIXED → build 4
- **Area:** Drive Mode follow-recenter gate. `MapViewRepresentable.shouldSyncDriveRegion` / updateUIView.
- **Observed (Kevin, build 3 w/ TF2-1):** scroll in drive mode "still snaps back, directionally better."
- **Root cause:** two flags gate follow-pause: `isUserInteracting` (FT-5, set SYNCHRONOUSLY on touch)
  and `driveFollowEnabled` (FT-10, set via async dispatch). The recenter (`syncDriveRegion`) was gated
  only on `driveFollowEnabled`. During an active drag the run loop is in tracking mode, so the async
  flip of `driveFollowEnabled` is deferred until the finger lifts — meanwhile each ~1 Hz GPS tick
  recenters mid-drag → snap-back. TF2-1 made the pause fire at all, but the async timing still lost the
  mid-drag race.
- **Fix:** also gate `syncDriveRegion` on `!isUserInteracting` (synchronous) → closes the mid-drag
  race. `shouldSyncDriveRegion(driveModeActive:driveFollowEnabled:isUserInteracting:)` now returns
  `driveModeActive && driveFollowEnabled && !isUserInteracting`. Full suite green (+1 race-case test).
- **Status:** 🟢 fixed; goes in build 4.
- **Lands in:** iOS (`MapViewRepresentable.swift`).

### TF2-1 🟢 Can't pan the live (Drive/Cruise) map while stationary — only zoom works — MERGED #52 (build 3)
- **Area:** Drive Mode follow-pause / pan detection. `MapViewRepresentable.regionWillChangeAnimated`.
- **Observed (Kevin, seated, TF2 build):** In the live screen, cannot pan at all — only zoom responds.
- **Root cause:** the FT-10 follow-pause trigger (`onDrivePanDetected` → flips `driveFollowEnabled`
  false → suppresses the recenter) is gated behind `guard parent.driveHeading != nil` in
  `regionWillChangeAnimated`. While STATIONARY (seated), speed is below the gate so `driveHeading`
  is nil → pan-detection never fires → follow never pauses → every GPS tick recenters on the user,
  yanking the pan back. Zoom survives because recenter only changes center, not zoom. (Would work
  while actually driving, since driveHeading != nil then — but broken seated, which is how you inspect.)
- **Fix:** gate the pan-detection on `parent.driveModeActive` (exists, line 193) instead of
  `parent.driveHeading != nil`, so any user pan pauses follow whether moving or not. One-line change;
  keep the FT-5 isUserInteracting logic + the heading-follow itself unchanged. Re-verify
  RegionSyncGuardTests + #31 smoke gate (sensitive path).
- **Status:** 🔴 open — fix identified. Goes in next TF2 build (build 3).
- **Lands in:** iOS (`MapViewRepresentable.swift`).

---

## Session 2026-06-08

### FT-11 🔵 Direction-of-travel on agent/sweeper reports (FEATURE, post-TF2)
- **Area:** Tier 3 report flow + marker rendering + one-way data. iOS + backend-data.
- **Request (Kevin, 2026-06-08):** When reporting an enforcement agent or sweeper, capture/show which
  WAY they're heading. Sweeper must follow the street's one-way direction (auto-derivable); an agent
  can go either way (user picks).
- **Proposed model:** direction = along-segment toward `from` vs toward `to` (segments carry from/to
  cross-streets + line geometry); render as a directional arrow on the marker. Store in pin `meta`
  (jsonb already exists; a `meta.direction` precedent exists). Sweeper: auto-derive from `osm_oneway.json`
  / segment one-way; on two-way streets fall back to user pick (or the side's traffic direction) — TBD
  in spec. Agent: user selects in the report sheet.
- **Decisions (Kevin, 2026-06-08):** (1) Agent direction = TWO-ARROW picker along the segment (toward
  each cross-street, labeled with cross-street names) in the report sheet. (2) Sweeper on a ONE-WAY
  street auto-derives direction; sweeper on a TWO-WAY street uses the same two-arrow picker (user picks).
- **Status:** 🟡 spec being written (post-TF2 build). iOS + backend-data; stores in pin `meta`, no schema change.

### FT-10 🔴 Drive/Cruise mode locks the map — can't zoom, pivot, or rotate
- **Area:** Drive Mode map interaction. `MapViewRepresentable` makeUIView gesture flags + follow camera.
- **Observed (Kevin, 2026-06-08):** While Drive/Cruise mode is on, the map is locked — can't zoom,
  can't pivot (pitch), can't turn the angle (rotate).
- **Cause:** makeUIView sets `mapView.isRotateEnabled = false` + `mapView.isPitchEnabled = false`
  (MapViewRepresentable.swift:442-443). Plus the continuous follow-recenter would fight manual
  zoom/pan anyway. Standard nav apps (Waze/Apple) allow pinch-zoom (and often pan with a "re-center"
  affordance) while keeping heading-up; rotation is usually locked to heading-up by design.
- **Design question:** which gestures to allow in drive mode (zoom? pitch? rotate?), and whether
  manual interaction should temporarily break follow + show a re-center button (Waze pattern).
- **Same subsystem as FT-7 + FT-8** (Drive Mode camera/interaction) → design together to avoid
  rework + regressions on the #31-sensitive path.
- **Lands in:** iOS (`MapViewRepresentable.swift`).

### FT-9 🔴 Bowery / 2nd Ave shown FREE on the left — should be metered/no-standing during the day (DATA)
- **Area:** Tile data / parking-rules classification + overlay color mapping. Backend-data + rules-engine.
- **Clarified (Kevin, 2026-06-08):** NOT "Lowry" — he meant **Bowery / 2nd Avenue** (Manhattan).
  Those curbs should be METERED or unavailable (no-standing) during the daytime, which is when he was
  using the app — but it showed FREE on the left side.
- **Investigation so far:** Both streets ARE in the dataset with real rules (Bowery: 105 segment-rows
  across 8 tiles — TRUCK_LOADING, NO_STANDING, NO_STOPPING; 2nd Ave sample: METERED 7AM–3PM +
  NO_STANDING 3PM–8PM). So NOT a missing-data problem. Leading hypotheses: (a) the rules engine /
  overlay maps METERED (and/or one-side curb regs) to a FREE/green state instead of a distinct
  metered state during the day; (b) specific blocks have rules on one side/curb but the opposite-side
  segment is empty → that side renders free; (c) side/arrow mismatch. "On the left" strongly implies a
  per-curb (side) issue on a one-way ave (2nd Ave is one-way SB).
- **Root cause FOUND (backend-data, `docs/qa/ft9-bowery-2ndave-investigation.md`):** branch-ordering
  bug in iOS `safetyLabel(for:at:)` (and PWA `actionableSafetyLabel()`): the "upcoming ASP → Free until X
  (.free)" guard fires BEFORE the METERED paid-hours check, so any METERED curb with an upcoming ASP
  returns `.free` "Free until…" (green chip + voice) during paid hours. Map polyline color (`currentState`)
  is CORRECT (amber meteredActive) — only text/chip/voice surfaces lie. **Systemic — affects every metered
  street citywide.** Fix: reorder so metered-active check precedes the ASP-free branch.
- **Status:** 🟡 iOS fix in progress (ios/ft9-metered-label-fix) for TF2. PWA fix = separate
  pwa-maintainer follow-up (not in TF2).
- **Lands in:** iOS rules engine (`safetyLabel`) now; PWA `index.html` (`actionableSafetyLabel`) later.

### FT-8 🟡 Drive/Cruise default zoom too wide — shows too many streets
- **Area:** Drive Mode / Cruise (Find Parking) camera zoom. `MapViewRepresentable.driveModeCameraSpan`.
- **Observed (Kevin, 2026-06-08, screenshot referenced but not received by agent):** Default zoom in
  Find-Parking/Cruise mode shows too many streets at once; wants it tighter — focused on the street
  you're currently on.
- **Cause:** `driveModeCameraSpan = 0.005°` (~2,000–2,300m altitude) in MapViewRepresentable.swift:222.
  Reducing it (e.g. ~0.0025–0.003°) zooms in to roughly the current block. One-constant tweak, same
  camera subsystem as FT-7 → bundle into FT-7 implementation; value tunable on-device.
- **Lands in:** iOS (`MapViewRepresentable.swift`). Bundled with FT-7.

### FT-7/8/10 🟢 Drive Mode camera & interaction — MERGED #49
- **MERGED to main via PR #49 (squash 5704d2a).** Unified fix: FT-7 (course heading while driving,
  0.3s animated camera + shortest-arc puck, dead-band 5°→2°), FT-8 (driveModeCameraSpan 0.005°→0.003°,
  tunable), FT-10 (driveFollowEnabled gate unlocks pinch-zoom + pan; interaction pauses follow, existing
  Re-center resumes heading-up). 426/0. QA PASS-WITH-NOTES (`docs/qa/ft7-8-10-drive-mode-qa.md`).
  On-device feel validation = Kevin's TF2 drive-test tonight (2026-06-08 ~9pm).
- **FT-7-followup (non-blocking cleanup, post-TF2):** wire the tested `selectDriveHeadingSource` helper
  into the production heading path (currently inline-equivalent, behaviorally correct); fix stale 0.005°
  comments in DriveZoomStyleTests; align didUpdateHeading stopped-path with helper Branch 2.
- **Area:** Drive Mode location/heading follow + car-pin (arrow) rotation. `MapViewRepresentable`
  (`syncDriveHeading`, location-update path, camera recenter) + heading source.
- **Observed (Kevin, driving, 2026-06-08):** (1) The arrow + map-follow update with visible LATENCY
  and feel "disjointed / not smooth at all" — nothing like Apple Maps / Waze, which interpolate.
  (2) The arrow points the WRONG / askew direction — not aligned to travel or the street. Kevin
  suggests defaulting the heading to the street's (one-way) direction of travel.
- **Hypotheses:** (a) location/heading applied at raw GPS cadence (~1 Hz) with `animated:false`
  recenters → steppy; no interpolation/animation between fixes. (b) Heading source is noisy
  (GPS course jitters at low speed, or magnetometer/device heading) and not snapped to the segment
  bearing → askew. Possible fix: smooth/animate the puck+camera between fixes, and derive/clamp
  heading toward the matched street segment's bearing (one-way direction).
- **Status:** 🔴 open — investigating to scope. Likely needs tech-lead spec (touches the
  #31-sensitive Drive Mode camera path; RegionSyncGuardTests + live-UI smoke gate mandatory).
- **Lands in:** iOS (`MapViewRepresentable.swift`, heading/location plumbing), no backend.

### FT-6 🟢 Customizable ASP reminder timing — multiple reminders + "night before" (FEATURE) — MERGED #48
- **MERGED to main via PR #48 (squash 8162018).** On-device Smoke A/B pending Kevin's next TF build.
- **Resolution (2026-06-08):** Built per `docs/ft6-customizable-reminders-spec.md`. Multi-select
  presets (15m/30m/1h/2h/night-before) as a global Settings default; default = {1h} for backward
  compat. QA PASS-WITH-NOTES, both nits resolved (`docs/qa/ft6-reminders-qa.md`). 395/0 tests, cold
  clean build + sim launch verified. **PR #48 open.** On-device Smoke A (Settings render/persist) +
  Smoke B (multi-preset notification delivery) pending Kevin's next TestFlight build → flip 🟢 after.
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
