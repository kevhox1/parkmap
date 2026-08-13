# WePark — Field Testing Log

Running log of fixes/errors Kevin observes while using the app on real hardware (TestFlight 1.0+).
Newest items at top. Each item: status, area, what was seen, proposed fix, and where it lands.

**Status legend:** 🔴 open · 🟡 spec'd / in progress · 🟢 fixed (PR merged) · ⚪️ won't-fix / deferred

---

## Round 5 — build 15 field observations (2026-08-12)

### FT-18 🔴 Drive Mode button layout/spacing looks bad — redesign toward Apple Maps (DESIGN)
- **Area:** Drive Mode chrome. `ContentView.swift` toolbar/overlay stack. Designer → iOS.
- **Observed (Kevin, simulator, build 16 candidate, 2026-08-13):** "the spacing on all the buttons in
  drive mode looks really bad… Let's consider Apple Maps as the base product. Maybe all buttons are on
  the bottom? I want it to be clean."
- **What's on screen today (from Kevin's screenshot):** a crowded top row of mixed-shape controls —
  `End Cruise` (pill, red), a speaker toggle (circle), `Report` (pill, orange), `Park here` (pill,
  blue) — overlapping map content, PLUS a separate vertical stack of 4 circular buttons hugging the
  right edge (locate, clock/Park-Until, directions, favorite). Two competing control languages
  (pills vs circles), two competing anchors (top row vs right rail), uneven gaps, and the cluster sits
  directly over the map exactly where the route ahead is.
- **Reference:** Apple Maps — bottom-anchored primary actions, a single control language, generous
  breathing room, minimal chrome over the live map.
- **Status:** 🔴 open — needs `@designer` proposal first (Kevin has said he lacks native-iOS design
  intuition; this is exactly the "catch it before TestFlight" case), then `@ios-engineer` implements.
- **⚠️ FILE COLLISION:** `ContentView.swift` — same file as FT-15 Stream B2 and FT-17's follow-up.
  Serialize.
- **Lands in:** `ios/WePark/WePark/ContentView.swift` (+ possibly new view files).

### FT-17a 🔴 Recenter pill appears only sporadically — gesture detection reads the wrong recognizers
- **Observed (Kevin, simulator, 2026-08-13, FT-17 branch):** "pinch to zoom out and pan works great,
  it holds and doesn't snap back. But the recenter pill is sporadic. It doesn't always appear."
- **ROOT CAUSE (orchestrator, code read):** `regionWillChangeAnimated` computes `isUserGesture` by
  scanning **`mapView.gestureRecognizers`** (`MapViewRepresentable.swift:1528`). But the only
  recognizers ever added to the map view itself are **our long-press and tap**
  (`:626`, `:643`) — MKMapView's own pan/pinch recognizers live on its internal subviews and are NOT
  in that array. So during a pinch, `isUserGesture` is true only when our tap/long-press happens to
  flicker into `.began/.changed/.ended` before cancelling → intermittent `followPaused` → intermittent
  pill. **FT-17 widened WHAT the trigger responds to without fixing HOW it detects.** The same latent
  unreliability existed pre-FT-17 for pan.
- **Fix direction:** install our own `UIPanGestureRecognizer` + `UIPinchGestureRecognizer` on the map
  view with `shouldRecognizeSimultaneouslyWith` → true (the `UIGestureRecognizerDelegate` and that
  simultaneous-recognition behavior already exist, `:806`, `:1667-1674`), and drive `followPaused`
  from those directly instead of inspecting `mapView.gestureRecognizers`.
- **⚠️ Kevin's test caveat:** the simulator run used a STATIC location (`simctl location set`), so
  "doesn't snap back" is **not conclusive** — with few/no GPS ticks nothing would pull the camera back
  regardless of `followPaused`. Real-device driving remains the true gate.
- **Fix implemented (`@ios-engineer`, 2026-08-13, PR TBD):** installed two dedicated, observer-only
  recognizers — `UIPanGestureRecognizer` + `UIPinchGestureRecognizer` — directly on the map view in
  `makeUIView`, with `shouldRecognizeSimultaneouslyWith` → true so they read `.state` alongside MapKit's
  native pan/pinch without ever intercepting or altering it. `regionWillChangeAnimated` /
  `regionDidChangeAnimated` now read `Coordinator.panGesture`/`pinchGesture` instead of scanning
  `mapView.gestureRecognizers`. Extracted the state→bool mapping into a new pure function,
  `MapViewRepresentable.isUserGestureActive(panState:pinchState:)` (no MKMapView/live-recognizer
  dependency, unlike the code it replaces — fully unit-testable), which feeds the existing
  `shouldPauseFollow(driveModeActive:isUserGesture:)`. **Explicit scope decision:** pan and pinch pause
  Drive Mode follow; tap (block select) and long-press (pin drop) do NOT — enforced structurally, since
  `isUserGestureActive`'s signature has no tap/long-press parameters at all. `isUserInteracting` (FT-5's
  free-browse snap-back guard) is re-pointed at the same fixed `isUserGesture` computation it already
  shared a code path with — it had the identical latent bug (tap/long-press flicker, not real pan
  detection), so this also fixes FT-5's guard, not just Drive Mode's. Tests: `WeParkTests/FT17aTests.swift`
  (11 new tests: 9 on `isUserGestureActive`, 2 composition tests through `shouldPauseFollow`).
  **COMPILE-UNVERIFIED** — written on a Linux VPS with no Xcode/simulator/toolchain.
- **Status:** 🟡 **fix implemented, awaiting Kevin's build + live-UI gesture smoke** (pill IS testable
  with a static location — it's gesture-driven, not GPS-driven; snap-back is NOT testable without real
  GPS ticks, per the caveat above). **Build 16 stays HELD** until Kevin confirms on-device/simulator.
- **Lands in:** `ios/WePark/WePark/Views/MapViewRepresentable.swift`, `WeParkTests/FT17aTests.swift`,
  `docs/tf2-11-drive-camera-ownership-spec.md` (Amendment Log).

### FT-17 🔴 Drive Mode: pinch-zoom doesn't pause follow — camera yanks back; want free zoom/pan + Recenter
- **Area:** Drive Mode camera ownership. `MapViewRepresentable.regionWillChange/regionDidChange` +
  `ContentView.followPaused` / `recenterDriveMode()`. **The single most regression-sensitive file pair
  in the codebase** (#31 saga, W8.5c-polish merge-then-same-day-revert).
- **Observed (Kevin, build 15, 2026-08-12):** "the map zooms back in when it's drive mode once I've
  zoomed out to take a look at something else. I think there should just be a 'recenter button' but it
  should allow free zoom/pan around."
- **ROOT CAUSE (orchestrator, code read — the requested feature ALREADY EXISTS but can't be reached):**
  1. The **Recenter pill already ships** (`ContentView.swift:1554`), gated on `followPaused == true`.
  2. `followPaused` is set ONLY by `onDrivePanDetected`, which fires only when a
     **`UIPanGestureRecognizer`** is active (`MapViewRepresentable.swift:1512-1522`).
  3. **Pinch deliberately does NOT pause follow** — that was the explicit **OQ-4 resolution** in
     `docs/tf2-11-drive-camera-ownership-spec.md`. Instead pinch captures the new altitude into
     `currentDriveAltitude` so the next GPS tick honors the user's zoom.
  4. But that altitude capture is **skipped whenever a pan recognizer was also active** (the `wasPan`
     guard, `MapViewRepresentable.swift:1551-1555`). Real two-finger pinches almost always drift, so
     MapKit's pan recognizer commonly fires → **the user's zoom is silently discarded.**
  5. Independently, `recenterDriveMode()` **deliberately resets `currentDriveAltitude` to the FT-8
     default** (`ContentView.swift:1723`) — so even a successful Recenter tap throws the user's zoom away.
  - Net effect: a pure pinch leaves follow ACTIVE → every GPS tick re-centers on the user at
    `currentDriveAltitude` → if the capture didn't land, that's the old tight zoom → **"it zoomed back in"**,
    and the Recenter pill never appears because `followPaused` was never set.
- **Kevin's ask = reverse the OQ-4 decision:** ANY user gesture (pan **or** pinch) pauses follow and
  surfaces Recenter; free zoom/pan until an explicit Recenter tap. This is the Waze/Apple pattern and is
  exactly the open "design question" FT-10 originally raised but resolved the other way.
- **⚠️ FILE COLLISION:** touches the same two files as **FT-15 Stream B2** (map tap-select). These two
  MUST be serialized, not run in parallel.
- **Status:** 🔴 open — root-caused, not yet implemented. Needs the live-UI simulator smoke gate on
  Kevin's Mac before merge (the gate that caught the W8.5c-polish regression).
- **Lands in:** `ios/WePark/WePark/Views/MapViewRepresentable.swift`, `ios/WePark/WePark/ContentView.swift`,
  and an OQ-4 amendment in `docs/tf2-11-drive-camera-ownership-spec.md`.

## Round 4 — build 14 field observations (2026-08-11)

### FT-16 🟡 `filming` layer has been silently empty for ~3 months — NYC film-permit feed went dry (DATA/INFRA)
- **Area:** `supabase/functions/ingest-film-permits/index.ts` + the daily pg_cron job in
  `supabase/02d-ingest-cron.sql`. Backend-data.
- **Found (orchestrator, 2026-08-11, while scoping FT-15):** our Edge Function pulls NYC Open Data
  `tg4x-b46p` (`index.ts:74`) and filters to **current/future** permits. That dataset's newest row is
  `startdatetime` **2026-05-12** (newest `enteredon` ~2026-05-07) across all **18,501** rows. So the
  current/future filter has matched **zero rows since ~May 12** — the cron runs daily, the RPC upserts
  nothing, and no error is ever raised. Zero rows have ever matched E 2nd St either.
- **It's an upstream break, not a retirement:** dataset metadata still reads Agency MOME, Automation Yes,
  **Update Frequency: Daily**. Socrata's `rowsUpdatedAt` shows 2026-08-10 (yesterday) but that's the asset
  being touched, not new rows landing — the row data itself is frozen. No replacement dataset to repoint at.
- **Same failure SHAPE as TF2-19:** a legitimately-empty pull and a broken pull look identical to us. TF2-19's
  lesson was a fail-CLOSED completeness gate; this pipeline has no equivalent, so a 3-month outage passed
  unnoticed. Recommend a "feed has produced no new rows in N days" alarm regardless of what NYC does.
- **Consequence for FT-15:** the crowd-report path is not a gap-filler for this feed — for filming it is
  currently the *only* signal. Open-data corroboration (`permit_id` matching) must stay strictly optional.
- **Investigated (`@backend-data`, 2026-08-11):** confirmed independently — hard cliff in monthly
  submissions (250–500/mo Jan–Apr 2026 → zero every month since June), not a gradual decline. Ruled out
  a candidate "intentional 3-month publishing delay" theory (surfaced via web search, unsubstantiated —
  observed submission→start lead time is single-digit days, not months). No replacement feed exists:
  catalog search found `tvpp-9vvx` ("NYC Permitted Event Information," CECM/SAPO) is the only actively-live
  film-adjacent dataset, but it's a different agency's general street-event feed (dominated by youth
  sports), covers only 5+ day permits, and would misrepresent the `filming` pin type if substituted.
  Full write-up: `docs/qa/ft16-film-permit-feed-investigation.md`.
- **Fix (PR #71, not yet merged):** kept the cron/filter as-is (not buggy — correctly empty given a dry
  upstream) and added a durable staleness guard: the function now independently probes upstream
  `max(enteredon)` every run (bypassing the current/future filter, bounded by an 8s timeout), logs
  loudly via `console.error` and writes to a new `public.ingest_runs` table
  (`supabase/02g-ingest-runs.sql`) with a tri-state `probe_status` (`fresh`/`stale`/`probe_failed`)
  when the feed has produced no new rows in 10+ days — or when the probe itself can't be trusted.
  Response JSON also carries `upstreamProbeStatus`/`staleDays` for a manual-invoke smoke test. Spec:
  `docs/tier1-open-data-ingest-spec.md` §3.9.
- **QA (`docs/qa/ft16-staleness-guard-qa.md`):** 🟡 ship with caveats (Edge Function) / **APPLY**
  unconditionally (migration — clean, idempotent, correctly RLS'd, zero blast radius). Agreed with the
  investigation and the keep-the-cron decision without pushback. Found a real defect: the freshness probe
  returned `null` — without throwing — on a 200-with-wrong-shape response (empty array, missing/renamed
  `latest` field), which collapsed to `stale: false` once persisted — indistinguishable from
  verified-fresh, reproducing the very "legitimately quiet vs. silently broken" ambiguity the guard exists
  to remove; also flagged a missing probe timeout that could block the invocation (and the durable log
  write) entirely on a stall. **Both fixed:** the probe now throws on every non-usable outcome instead of
  returning `null` (→ distinct `probe_failed` state, stored via the tri-state `probe_status` column above,
  never conflated with `fresh`), and the probe fetch is now bounded by the 8s timeout noted above so a
  stall degrades to `probe_failed` instead of hanging the whole invocation. Threshold rationale also
  corrected from an inferred ("~9x margin," monthly aggregates) to a measured claim (~2x margin against the
  largest genuine day-level gap in the dataset's steady-state history).
- **⚠️ DEFERRED FOLLOW-UP — FT-16a, alerting (Kevin's call, 2026-08-11):** the guard's output is a
  `console.error` + a queryable `ingest_runs` row, and **nothing polls either**. QA's point stands: this
  makes the next outage *technically visible if you check*, not *noticed* — and a human demonstrably won't
  check, which is exactly how this ran 3 months. A small scheduled job reading `ingest_runs.probe_status` and
  sending one email is the proportionate fix, but no alerting mechanism exists anywhere in this repo yet, so
  it gets its own scoped pass rather than riding along in #71. **Named explicitly so it isn't silently
  dropped — "we'll notice next time" is the assumption that already failed once.**
- **Status:** 🟡 **PR #71 open** — SQL migration + Edge Function change, **not yet applied to production**
  (Kevin applies after QA, per `.claude/TEAM.md`). No client changes required; not a blocker for FT-15.
- **Lands in:** `supabase/functions/ingest-film-permits/`, `supabase/02g-ingest-runs.sql`,
  `docs/tier1-open-data-ingest-spec.md`.

### FT-15 🟡 Temporary block restrictions from posted paper signs (film shoot / closure) — user report + block-scoped override (FEATURE, large)
- **Area:** New primitive — a **block-scoped, time-windowed restriction override** on top of the
  baked tile rules. Spans backend (schema + RPC), data (block resolution), iOS (report flow + render).
- **Observed (Kevin, on-device photo, 2026-08-11, night):** two laminated orange **NYPD "NO PARKING —
  FILM SHOOT"** placards zip-tied to a pole. Legible fields: posted **WED 8/12 @ 12pm**; *vehicles
  must be moved by* **THURSDAY 8/13/26**; shoot time **6AM**; project name **North Six**; location
  manager **Matthew, 347-996-8207**. Boilerplate: *"signs can be held a maximum of 24 hours in
  advance of the date & time indicated below (as spaces become available)."*
- **Affected extent (Kevin):** the whole of **E 2nd St between 3rd Ave and 1st Ave** — note this is
  **2 blocks × 2 curbs = 4 blockfaces**, not one segment.
- **Request:** "ingest this and update information for specific blocks… report 'street closure' or
  something like that." I.e. a user sees a paper sign, reports it, and every affected blockface
  reflects the restriction for its window — then reverts automatically.
- **What already exists (do NOT rebuild):** `pin_type` enum already carries **`filming`** and
  **`construction`** (Tier 1, `source='open_data'`, `lifespan='session'`, `docs/typed-pin-schema-spec.md`
  §156/§319). `upsert_filming_pin` RPC + `ingest-film-permits` Edge Function + pg_cron job already
  ship (`supabase/02d-ingest-cron.sql`) pulling the NYC Film Permits open dataset. Spec §AC-S5 already
  anticipates a **crowd-sourced** `filming` pin. Shipped `ReportSheet` currently exposes only Tier-3
  ephemeral types (enforcement/sweeper), so the report UI is the missing half.
- **The four real gaps:** (1) **point → block scope** — every pin today is a single lat/lng; this
  needs to attach to blockfaces and override baked rules; same primitive **TF2-15 construction layer**
  needs → build once, use twice. (2) **explicit time window** (`starts_at`/`ends_at`), vs today's
  `expires_at`-only session model. (3) **sign photo → structured fields** (manual form vs
  photo-as-evidence vs vision OCR). (4) **trust/abuse** — a crowd pin that overrides authoritative
  rules can wrongly say "free"; needs confirm/resolve + RLS + hard expiry, and can be cross-checked
  against the already-ingested permit feed (`permit_id`) since this exact shoot is likely in it.
- **Kevin's decisions (2026-08-11):** (a) ingestion = **photo + confirm form**; vision/OCR is phase 2 and
  only ever PRE-FILLS that form, never the ingestion path. (b) render = **overlay, not recolor** — a crowd
  report must not silently repaint authoritative baked rules. Plus hard expiry + existing confirm/resolve.
- **Status:** 🟡 **SPEC'D** — `docs/ft15-tf215-temporary-block-restrictions-spec.md` (tech-lead, 2026-08-11),
  covering FT-15 + TF2-15 as one shared primitive. Phase 1 = multi-block both-curbs **map tap-select**
  (deliberately avoids re-solving FT-14-class name matching on-device — block identity read verbatim off the
  tapped segment via a new `Segment.blockfaceKey`), photo evidence stored PII-safe (never shown to other
  users — the placard carries a real name + cell), `starts_at`/`expires_at` with type defaults + hard
  ceiling, marker-based render, construction reusing the identical flow to prove the abstraction.
  Sizing: **backend 1 session, iOS 4–6 sessions** — not a quick add-on to `ReportSheet`.
  **Two real gaps the spec found:** neither existing `CommunityPinService` fetch channel would ever return a
  `source=crowd, lifespan=session` row (a third channel is required, else we insert rows the app never
  shows); and `auto_resolve_on_dispute` only covers `lifespan='ephemeral'`, so a block report has no
  dispute-driven resolution path today. ⏳ **OQ-1 awaiting Kevin:** marker-only render acceptable for
  phase 1, or dashed/hatched polyline in the initial cut?
- **Lands in:** `supabase/` (schema + RPC), `build/`-side block resolution, iOS report flow + render.
- **Related:** TF2-15 (construction layer) — should share this primitive. TF2-4 (school-zone wrong
  side) is also on **E 2nd** and still needs the exact block from Kevin — different issue, same street.

## TF2 Round 3 — build 13 drive-test feedback (2026-07-09)

Kevin drove build 13. **TF2-11 Option A zoom VERIFIED on-device** ("zoom is working better") — the
4-round zoom saga is closed. **TF2-14 curb offsets: improved on-device** ("mostly went over closer" —
accepted; residual lever = `DIVIDED_MEDIAN_ALLOWANCE_M` if ever needed). New findings below, all
proceeding through the proper flow (spec → build → QA → merge), no expedite.

**Approvals (Kevin, 2026-07-09):** TF2-16 spec approved → engineering started. TF2-17 + TF2-18 ship
as ONE bundled PR (queued behind TF2-16 — file overlap on DrivingContextService/ContentView).
FT-12 all 7 OQ recommendations accepted → engineering started (file-disjoint, runs in parallel).

### TF2-19 🔴 Houston/Bowery (major roadways) show FREE — should be metered / no-standing daytime
- **Area:** Tile data correctness and/or rules-engine display mapping. Backend-data first.
- **Observed (Kevin, build 13, 2026-07-09):** "parking appears as free on those blocks, but this
  cannot be right. Parking is metered during the day with 'no standing' signs on most of the major
  roadways in NYC." Same streets regen 5 (TF2-14) gave special divided-street width handling.
- **History:** FT-9 déjà vu (Bowery/2nd Ave shown free) — BUT FT-9's root cause was safetyLabel
  branch-ordering; the map polyline color was verified CORRECT then. If the map itself now reads
  free, it's a different failure. Prime suspects: (a) regen 5's per-street divided handling dropped
  or misassigned rules on the allow-list streets (Houston/Bowery/Allen/Forsyth/Delancey); (b) side
  gap — rules on one curb, opposite-side segment empty → renders free; (c) zone-cap / stub-filter
  over-trim from regens 4–5; (d) engine daytime mapping regression (less likely — FT-9 verified it).
- **ROOT CAUSE FOUND (backend-data, `docs/qa/tf2-19-houston-bowery-free-investigation.md`):** regen 5
  silently shipped an INCOMPLETE pull of the MAIN Socrata sign dataset (`nfid-uabd`) — unrelated to
  the TF2-14 code (curb-offset diff never touches the fetch/rule path). Evidence: citywide pre/post
  diff across ~988 tiles shows METERED −48.1%, NO_PARKING −46.6%, NO_STANDING −42.0%, TRUCK_LOADING
  −37.7% while every ASP_* category (separate fetch) held flat (≤0.5%); geometry-identical segments
  lost rule content outright. `fetchSocrataDataset()` is fragile: no retry (bare `break` on error),
  no `$order`, no app token, no completeness validation — MAIN is ~16 pages vs ASP ~5, far more
  exposed to a mid-pull failure. Engine EXONERATED (correctly renders the defective data — the
  opposite failure mode from FT-9). iOS bundle tiles byte-identical to `tiles/` (not packaging).
- **⚠️ BUILD-13 IMPLICATION: tiles in build 13 are defective citywide** — restricted curbs render
  free block-by-block unpredictably. Do NOT upload 13 to TestFlight; regen 6 → build 14.
- **Status:** 🟢 MERGED #63 (`5f76b6b`, 2026-07-09) → **PWA HEALED (cache v38 live)**; iOS fix rides
  build 14. Hardened fetch: retry+backoff, `$order=:id` stable pagination, optional app token,
  fail-CLOSED count(*) completeness gate (aborts build before any tile write — QA pass-2 verified
  incl. NaN-parse edge). Regen 6 measured + independently recounted by QA byte-for-byte: METERED
  6,673→15,153, NO_STANDING 9,373→18,978, ASP flat, corridors recovered on identical geometry,
  TF2-14 offsets unchanged. Duplication-vs-recovery adversarial check → benign recovery (dup-rule
  ratio flat ~32-33% across snapshots); regen 6 is likely the first genuinely COMPLETE pull ever
  (old fetch had no `$order` → every prior regen plausibly missed rows). QA: pass 1 SHIP WITH
  CAVEATS → fail-closed fix `139f738` → pass 2 SHIP CLEAN (`docs/qa/tf2-19-regen6-qa.md`).
  ⏳ Kevin on-device: Houston/Bowery should read metered/no-standing daytime (build 14 / PWA now).
- **Follow-up (pwa-maintainer, minor):** `index.html` `APP_VERSION` stuck at v36 vs sw.js v38 —
  cosmetic debug-chip drift, QA pass-1 Finding #2.
- **Lands in:** `build/preprocess.js` + tiles regen 6 (PWA + iOS Resources) + sw.js. No engine change.

### TF2-20 🔴 Bowery still mostly GREEN on build 14 at Sat 5pm — data says RED/AMBER (engine/render discrepancy)
- **Observed (Kevin, build 1.0(14) confirmed via Settings footer, 2026-07-12 ~5pm ET Sat):** almost all
  of Bowery renders green.
- **Data analysis (orchestrator, regen 6 tiles on main):** Bowery carries dense correct rules —
  `NO STANDING 4PM-7PM EXCEPT SUNDAY` (ACTIVE at Sat 5pm), `2 HMP 10AM-7PM EXCEPT SUNDAY` meters
  (paid until 7pm Sat), bus stops, truck loading. Faithful engine simulation at Sat 17:00 ET over
  all street=BOWERY segments: **67 RED / 22 AMBER / 14 GREEN.** (Same sim over build-13's regen-5
  tiles: 33 GREEN / 29 RED / 17 AMBER — matches what a build-13 install would show, but Kevin
  confirmed 14.) Verified correct: tile data, ParkingRule decode shape, isScheduleActive semantics,
  day convention (0=Sun..6=Sat both sides), Date+ET (minuteOfDayET/dayOfWeekET genuinely ET).
- **Hypothesis space:** (a) bundled Resources tiles in the built .app ≠ repo tiles (regen 6 added 8
  NEW tile files — are they in the target? did Bowery segments resegment into them?); (b) TileLoader
  loads stale/wrong tiles at runtime; (c) overlay recolor staleness (rebuildOverlays timing — colors
  computed at an earlier time and not refreshed); (d) Category decode failure dropping rules
  silently; (e) a Park Until filter accidentally active. Kevin asked to tap a green Bowery block —
  sheet rule list distinguishes rules-loaded-but-mis-evaluated vs rules-missing-on-device.
- **Status:** ⚪️ **CLOSED — NOT A BUG** (diagnosis `docs/qa/tf2-20-bowery-green-diagnosis.md`,
  2026-07-12). **2026-07-12 is a SUNDAY** — the orchestrator's analysis above mislabeled it
  Saturday (Kevin never said Saturday). Bowery's dominant signs are "EXCEPT SUNDAY" → green at
  Sun 5pm is CORRECT. Real-decoder+engine harness on the actual bundle: Sat Jul 11 17:00 ET =
  67 RED / 22 AMBER / 14 GREEN (matches the sim above); Sun Jul 12 17:00 ET = 18 RED / 0 AMBER /
  85 GREEN (matches Kevin's observation exactly). Bundle audit clean (all 1032 tiles incl. the 8
  regen-6-new ones, byte-identical); recolor path recomputes fresh every 60s (no staleness);
  parkUntilMode defaults off. Every layer correct — regen 6 fix IS effective.
  **Process lesson: verify day-of-week against a calendar before diagnosing schedule-dependent
  behavior.** Residual real-world check for a WEEKDAY/Saturday drive: Bowery should read red/amber
  during those windows.
- **Lands in:** nothing — working as intended.

### FT-14 🔴 Coverage gaps — sign data missing for ~half of street-miles; root cause on Kevin's block = cross-street name-join failure
- **Observed (Kevin, driving east on Bleecker near LaGuardia Pl):** streets with no data at all in the
  app (no polylines — absence, not gray).
- **Coverage analysis (orchestrator; `scripts/coverage-report.js`, run after any regen):** vs CSCL
  centerline miles, Manhattan overall **43% covered** (undercounts ~10-15pts due to intersection
  setbacks + one-sided streets — ranking is the signal). Weakest: FiDi 34%, East Harlem 36%,
  Harlem 38%, **LES 40%**. Strongest: Greenwich Village 70%, SoHo 65%, Nolita/Noho 63%.
- **Kevin's exact gap root-caused:** Bleecker LAGUARDIA PLACE→MERCER has ZERO faces (both sides) in
  tiles, and Thompson→LaGuardia is south-side-only. Socrata HAS the signs (12 rows LA GUARDIA
  PLACE→MERCER N+S; 2 rows THOMPSON→LA GUARDIA PLACE N). **The dropped rows spell it "LA GUARDIA
  PLACE" (space); the surviving rows "LAGUARDIA PLACE" (no space)** — NYC's dataset is internally
  inconsistent and our cross-street normalizer only bridges one variant → rows silently dropped at
  the join. Likely a citywide CLASS (spacing variants, ST/SAINT, etc.) worth a chunk of the
  uncovered 57%.
- **INVESTIGATION COMPLETE (`docs/qa/ft14-join-drop-investigation.md`):** 6,044 of 54,987 sign rows
  (11.0%) drop at the name-join. Buckets: alias/co-names ~2,900 (Lenox/Malcolm X, ACP Jr Blvd ×3
  spellings, Fred/Frederick Douglass, Ave of the Americas, Cathedral Pkwy), SAINT↔ST 1,109
  (St Nicholas Ave!), spacing variants 103 (LaGuardia/MacDougal/F D R), genuinely-absent-from-OSM
  ~800 (dead ends/ramps/plazas — not fixable by renaming). Bleecker's 12 rows verified in the drop
  log (SPACING_VARIANT). Candidate 3-part fix (SAINT/ST swap + collision-checked spacing fallback +
  8 hand-verified aliases, confined to `osmName()`/`NYC_TO_OSM`) tested in scratch: **recovers
  4,204 rows (69.6%) → +31 curb-miles, citywide 43%→47%, HARLEM 38%→64% (+26 pts)**. Low-risk
  (exact-match-gated vs the finite 2,813-street OSM key set; 3 collisions found, all same-street
  duplicates). Separate follow-ups flagged, NOT bundled: 1,528-row zone-construction loss;
  dead-end/ramp handling. Caveat: recovers ~4 of the ~57 uncovered points — the bulk of the gap is
  likely blocks where NYC posts no signs at all (bigger, different problem).
- **Status:** 🟢 **MERGED #68** (`b5da617`, 2026-08-11) → rides **build 15** (with FT-13 ? button).
  Verified pre-PR by orchestrator: coverage 43%→47%, Harlem 38%→64%, Kevin block recovered both
  sides, zero category regressions, 39 new Harlem-row tiles. ⚠️ **Merged on Kevin's call without a
  completed independent QA pass** — the QA agent was stopped mid-run (it had confirmed the 24 new
  Bleecker faces first); no report exists in `docs/qa/`. Post-merge QA on `main` still available
  before the archive. ⏳ Kevin on-device (build 15): Bleecker @ LaGuardia colored, Harlem jump.
- **Lands in:** `build/preprocess.js` normalizer + regen 7.

### FT-13 🟡 Parking 101 "?" button on the map toolbar (FEATURE, small)
- **Request (Kevin, 2026-07-12):** loves the Parking 101 guide ("very good"), wants it accessible
  all the time — approved a `?` (questionmark.circle) button on the main map toolbar.
- **Scope:** one button in the existing ContentView toolbar stack → `activeSheet = .parkingGuide`
  (case exists since FT-12). Follow the button anatomy standardized in the TF2-18 pass; 44×44 tap
  target; accessibility label. No spec needed (single-file tweak per TEAM.md sizing).
- **Status:** 🟢 MERGED #67 (`5c825bb`, 2026-07-13) → next build (15, whenever cut). `?` button in
  the gear cluster (HStack, identical 44×44 anatomy), opens `.parkingGuide` sheet, hidden during
  Drive Mode via explicit tested gate `parkingGuideButtonVisible(driveModeActive:)`. 585/0 tests
  (+3 FT13Tests, 0 flakes across 3 runs). QA SHIP CLEAN (`docs/qa/ft13-toolbar-button-qa.md`).
  ⏳ Kevin: tap-through on device (sandbox couldn't gesture).
- **Infra note (QA, out of scope):** a passcode-locked physical iPhone paired to this Mac makes
  Xcode's test diagnostics collector time out (600s), inflating local test runs to 30+ min —
  disconnect/unpair it to speed up every future suite run.
- **Lands in:** iOS (`ContentView.swift` toolbar stack only).

### TF2-16 🟡 Drive Mode heading spins/hunts at low speed — default to one-way street direction
- **Area:** Drive Mode heading source. `LocationService` heading stabilizer + `MapViewRepresentable.syncDriveHeading`.
- **Observed (Kevin, build 13):** heading not synced properly all the time; "sometimes it will spin
  and look for its direction" — **at low speed when approaching an intersection or turn.**
- **Diagnosis:** heading is GPS course + EMA with speed gate `DRIVING_HEADING_MIN_SPEED_MPS = 0.5`
  (lowered from 1.8 in TF2-3 so cruise-crawl wouldn't freeze the arrow). Below ~2–3 m/s GPS course is
  noisy; at 0.5 the noise passes the gate and the EMA turns it into a slow visible swing — exactly at
  intersection-approach speeds.
- **Direction (Kevin):** when matched to a **one-way** segment and course confidence is low (slow /
  poor accuracy), snap heading to the segment's bearing in the one-way direction (`oneway` /
  `onewayToward` shipped on segments in the FT-11 regen). Fast + clean course still wins. Two-way
  streets: segment bearing in whichever direction is closer to last good course. Hysteresis so the
  source doesn't flip-flop. ⚠️ #31-sensitive camera path → tech-lead spec + worktree engineer + QA +
  live-UI smoke gate + Kevin drive-test.
- **Status:** 🟢 MERGED #64 (`329647d`, 2026-07-09) → build 14. Pure hysteresis state machine in
  new `Services/DriveHeadingSnap.swift` (speed+courseAccuracy gating only — course/EMA disagreement
  deliberately excluded as it's the signature of a real turn); wiring confined to
  `ContentView.handleLocationUpdate`; ZERO diff to MapViewRepresentable (verified by builder + QA
  independently). 533/0 tests (+18), deterministic across runs; hysteresis boundaries hand-traced
  by QA (wraparound, at-threshold, turn-recovery) — clean. QA SHIP WITH CAVEATS
  (`docs/qa/tf2-16-heading-snap-qa.md`): the only Significant is that live Drive-Mode-entry
  screenshot is unexercisable in sandbox (no gesture injection) — covered by the stronger gate.
  ⏳ Kevin on-device drive-test (build 14) = the gate: heading locks to street at intersection
  approaches, no spin/hunt, hands back to GPS course through turns.
- **Nits → tech-debt batch:** `snappedHeading` `lastGoodHeading` doc comment overstates
  ("last trustworthy EMA before confidence dropped" vs actual live current-tick EMA); cosmetic.
- **Lands in:** iOS (new `Services/DriveHeadingSnap.swift`, `LocationService.swift`,
  `ContentView.handleLocationUpdate`, `DrivingContextService.matchedSegment` exposure).

### TF2-17 🟡 Bottom-card Left/Right chips should read "Free until X"
- **Area:** Drive Mode bottom card copy. `DrivingContextService.aggregateSide` → `SafetyLabel`.
- **Observed (Kevin, build 13):** wants the left/right readings to say "Free until X".
- **Diagnosis:** pre-TF2-7 the chips carried the engine's full per-segment label ("Free until Thu
  9:30am"); TF2-7's side-aggregation replaced chip text with generic category copy ("Free parking
  sections — check signs"). The engine still computes "Free until X" per segment.
- **Fix direction:** when a side aggregates to free, surface the **earliest** upcoming restriction
  across that side's free segments (conservative min) → chip reads "Free until Thu 9:30am". Keep
  severity colors. Mostly `DrivingContextService` + tests.
- **Status:** 🟢 MERGED #66 (`08a0233`, 2026-07-10, bundled with TF2-18) → build 14. Chips now read
  "Free until Thu 9:30am"-style (earliest restriction across the side's free segments, conservative
  min); new `.comingSoon` severity restores the orange tier in chips (was silently collapsed to
  green). Voice locked unchanged by regression test (`.comingSoon` still voices as free — QA
  hand-traced). FT-9-class regression test in. QA SHIP WITH CAVEATS, 0 blocking
  (`docs/qa/tf2-17-18-chips-design-qa.md`). ⏳ Kevin drive-test: chips show "Free until X".
- **Lands in:** iOS (`DrivingContextService.swift`, `SafetyLabel.swift`).

### TF2-18 🟡 Drive Mode UI layout clunky + color scheme visibility — holistic design pass
- **Area:** Drive Mode surface: bottom card, chips, End Drive pill, approaching strip, arrival
  prompt, sign-check sheet; W4.5 palette as used in the drive context.
- **Observed (Kevin, build 13):** "layout is still a bit clunky and the color scheme can be improved
  for visibility." The drive surface grew feature-by-feature across ~8 PRs without a holistic pass;
  palette was tuned for map polylines, not glanceable in-car reading in sunlight.
- **Direction:** designer end-to-end review vs Apple Maps/Waze glanceability conventions → findings
  doc → one engineer pass (may bundle TF2-17 since both touch the bottom card).
- **Status:** 🟢 MERGED #66 (`08a0233`, 2026-07-10, bundled with TF2-17) → build 14. Shipped from
  the review: solid-fill chips w/ black text — WCAG contrast now 5.92–10.39:1 in BOTH modes (was
  1.4–2.6:1 failing in Light; the review's own white-text rec failed the math at 2.22:1, engineer
  overrode with justification, QA recomputed + confirmed); orange `.comingSoon` tier restored in
  chips; Recenter pill clearance coordinated with bottom-card height; End Drive pill offset
  44→100pt; 44×44 tap targets (SignCheckConfirmView); button-anatomy pass; palette doc §8 added.
  565/0 tests. QA SHIP WITH CAVEATS, 0 blocking, 3 nits routed to drive-test
  (`docs/qa/tf2-17-18-chips-design-qa.md`). ⏳ Kevin drive-test: sunlight legibility = the gate.
  Review filed at `docs/design/drive-mode-ui-review-2026-07-09.md`:
  P1s: chip contrast FAILS WCAG in Light Mode (~1.4–2.6:1 — full-saturation severity text on
  15%-tint of same color; fine in Dark ~9.8:1 → palette was tuned on dark backdrops; this is the
  daylight-visibility complaint); drive chips DROP the orange "restriction soon" tier the map has;
  Recenter pill hardcodes bottom offset, unaware of bottom-card height (same class as the fixed
  top-banner clearance, never mirrored at bottom). P2s: inconsistent button anatomy, mismatched
  toolbar-cluster offsets (44 vs 100pt), 3 uncoordinated bottom card systems, amber collision
  (ASP banner vs metered chips), chip capacity vs TF2-17's longer copy. Suggested single engineer
  PR bundling TF2-17. Awaiting Kevin approval of scope.
- **Lands in:** iOS views (post-review).

### FT-12 🟡 Beginner's manual — "free parking in NYC 101" education (FEATURE)
- **Area:** Onboarding / education content. iOS (extends or sits beside the PR #45 Help & FAQ).
- **Request (Kevin, 2026-07-09):** a beginner's manual for new users: free parking in NYC — why it's
  doable and easy, how much money it saves, **with images of what signs say and how to interpret
  them.**
- **Notes:** Help & FAQ screen exists (PR #45, content at `docs/in-app-faq-content.md`, reachable
  from Settings) — text-only, no sign visuals, no savings pitch. Spec to decide: extend FAQ vs new
  "Parking 101" surface; first-launch entry point vs Settings-only; sign-image asset strategy
  (rendered sign replicas vs photos); savings framing (garage $/mo vs free-with-effort).
- **Status:** 🟢 MERGED #65 (`eb6af94`, 2026-07-09) → build 14. All 7 OQs approved as recommended.
  New `Views/ParkingGuide/` (guide screen + 4 sections + `SignPlateView` vector replicas +
  first-launch `ParkingGuidePromptBanner`), `docs/parking-101-content.md` source-of-truth,
  `MoneyMathConstants` + `ParkingGuidePromptGate`, Settings row + FAQ cross-link. QA pass 1 SHIP
  WITH CAVEATS → content fix `ef3969d` (ladder now teaches No Parking = merchandise+passengers OK
  vs No Standing = passengers only vs No Stopping = nothing — QA-caught gap inherited from the
  SPEC, not engineering) → pass 2 SHIP CLEAN (`docs/qa/ft12-parking-guide-qa.md`). Merge conflict
  vs TF2-16 on ContentView @State blocks resolved keep-both by orchestrator; combined state
  verified 549/0 before push.
  ⏳ **Kevin on-device pass items (nobody could tap-through in sandbox):** (1) Settings →
  "Parking 101" row opens the guide; (2) FAQ cross-link; (3) ladder plates at large Dynamic Type;
  (4) fresh-install banner shows once, non-blocking, ~8s auto-hide.
- **Lands in:** iOS UI + bundled content/assets; no backend.

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
  - Option A nits (PR #62): onDrivePinchZoomed doc says !followPaused (fires regardless); FT10Tests
    header test-count arithmetic wrong (says 525, actual 514); stale isUserInteracting comment refs
    deleted shouldSyncDriveRegion.
  - TF2-16 nit (PR #64): `DriveHeadingSnap.snappedHeading` `lastGoodHeading` doc comment overstates
    trustworthiness (actual value is live current-tick EMA in the 0.5–1.5 m/s band). Comment-only.
  - Polyline non-render at cold launch in SIM (fixed-location conditions): reproduced identically on
    main pre-TF2-16 by QA — pre-existing, likely the launch-recenter vs rebuildOverlays timing gap
    (only re-triggered by 60s timer/segment/selection change). Sim-observed; Kevin has NOT reported
    it on-device. Own ticket if it shows up in the field.

## TF2 Round 1 — on-device testing of build 1.0(2) (2026-06-08 evening)

Findings from Kevin testing the TF2 build (FT-1/5/6/7/8/9/10) on his iPhone. Labeled TF2-N.

## TF2 Round 2 — build 10 findings (2026-06-12) — SPEC-FIRST per Kevin

### TF2-14 🔴 Houston (widest streets) lines still mid-road — width-tier ceiling → CSCL real widths (regen 5)
- **Observed (Kevin, build 11):** Houston north-side green line should sit on the NORTHERN CURB; it's
  mid-road. Houston is ~35m+ curb-to-curb w/ median — the wide-tier 10m offset can't reach the curb.
- **Decision:** un-defer the CSCL/LION real-width ingestion (spec'd in docs/tf2-12-13-curb-geometry-spec.md)
  as regen 5. Validate specifically on HOUSTON north curb + BOWERY. Handle divided/median streets
  (CSCL models carriageways separately — join carefully).
- **Status:** 🟢 SHIPPED → build 13 (PWA cache v37). Root cause was NOT the join (name canon matches +
  real midpoints find ways; the probe's NO-GO was a bad hand-typed coord). Real issue: per-SEGMENT
  divided detection fired inconsistently (Houston 10-18 ragged; 2nd Ave false 18s; overshoot). FIX:
  PER-STREET uniform offset (median CSCL streetwidth, computed once → spread 0, no zigzag), divided
  allow-list (Houston/Bowery/Allen/Forsyth/Delancey)=7m+width/2, others=max(width/2*0.88, tier floor),
  clamp 4-14m; avenue floor fixed (WIDE regex matches canonical 'AVE'). Validated tiles: Houston/Bowery
  ~12.7m parking lane (was 10m mid-road), 2nd Ave 10m (no regression), side streets 6m, Elizabeth W free.
  ✅ Kevin on-device 2026-07-09 (build 13): "mostly went over closer" — accepted. BUT surfaced
  NEW TF2-19: those same blocks now read FREE (should be metered/no-standing daytime) — see Round 3.

### TF2-15 🔵 Bowery curb is metered + UNDER CONSTRUCTION — temporary conditions layer (ROADMAP)
- **Observed (Kevin):** the Bowery stretch isn't parkable at all right now (construction), regardless of
  the metered signage the tiles describe. Kevin correctly notes this is future scope.
- **Direction:** static sign tiles = legal signage only. Temporary reality = the construction layer:
  ingest NYC street-construction permits as Tier 1 `construction` pins (pin type already in schema
  02-pins) + crowd reports for what permits miss. Roadmap item for the community/data milestone —
  not a tile-pipeline fix.
- **Status:** 🔵 logged for roadmap.

### TF2-11 🔴 Zoom: bounces TWICE, still ends zoomed out — .follow re-asserts; one-shot can't win
- **Observed (Kevin, build 10):** two bounces (our entry zoom + our re-apply both visible) then MapKit
  zooms out again and wins. Conclusion: `.follow` re-asserts its preferred altitude on subsequent
  location updates — any one-shot correction loses; repeating correction = camera war.
- **Options:** A) custom follow camera in drive mode (drop .follow; per-fix animated setCamera with
  center/heading/pitch/altitude — full control, Waze-style; safe now that the region-binding
  architecture is gone). C) setCameraZoomRange clamp during drive (~1 line; MapKit can't zoom past
  max; trade-off: caps pinch-out). Recommend: spec A, try C as quick experiment first.
- **EXPERIMENT VERDICT (Kevin, build 11): FAIL — WORSE.** "Bouncing around and unsettled": the clamp
  turns .follow's one-time zoom-out into a continuous fight (MapKit retries past the ceiling every GPS
  tick, gets blocked, retries). Option C dead.
- **Status:** 🟢 OPTION A MERGED #62 → build 12. Custom follow camera: per-GPS-tick animated setCamera
  (center+pitch30+our altitude; heading owned by course-EMA), NO .follow → nothing fights the camera.
  Deleted clamp + TF2-8 re-apply + all tracking-mode machinery. QA PASS-WITH-NOTES
  (docs/qa/tf2-11-option-a-qa.md), 514/0, both adversarial traces pass. ✅ **VERIFIED ON-DEVICE
  (Kevin, 2026-07-09, build 13): "zoom is working better" — follows and stays tight. Saga closed.**

### TF2-12 🔴 Bowery lines mid-road — side-lines CONVERGE to 0m on curved stretches + width ceiling
- **Measured:** Bowery median E/W separation 20.5m (wide offset IS applied), BUT around
  Grand→Broome/Hester the sides converge to 0.0-12m (side-selection flips on a curved/ambiguous
  stretch → both lines at centerline = Kevin's screenshot), and southern Bowery is wider than 20m.
- **Direction:** name-tier guessing has hit its ceiling. Use NYC CSCL/LION per-segment street WIDTH
  for the offset (real width/2 − ~2m) + fix the converging-side anomaly (consistent normal selection
  per block face). Backend-data spec dispatched.
- **Status:** 🟢 regen 4 SHIPPED (76fecb3) → PWA (cache v36) + build 11. Block-level hemisphere lock +
  zero-length stub filter (the actual 0.0m culprits). Validated: Bowery min E/W separation 0.0→19.9m,
  median 20.4m. CSCL widths deferred. ⚠️ South-of-Delancey Bowery has a center median — may still read
  slightly in-lane; CSCL/calibration is the next lever if Kevin's eyes say so.

### TF2-13 🟡 Elizabeth St north end shows "No Parking" though block is free — sign-zone EXTENT (not offset)
- **Verified by diff:** the W-side Houston→Bleecker NO_PARKING dominance exists in BOTH the previous
  and current tile builds — NOT caused by the TF2-10 offset change. Likely a garage curb-cut "No
  Parking" sign whose zone stretches to the block end (sign-zone extends until next sign).
- **Fix candidates:** zone-extent capping for curb-cut-class signs in the pipeline; and/or Tier 2
  community sign-corrections (the product answer for per-curb source errors). Folded into the
  backend-data geometry/data spec.
- **Status:** 🟢 regen 4 SHIPPED — zone cap implemented (isolated towards-arrow NO PARKING ANYTIME,
  ~50ft cap, 4 guards). Validated: Elizabeth W now ASP everywhere except the ~21m garage pocket.
  Blast radius ~614 faces citywide improved. (Park-here sheet TF2-9 confirmed better on-device.)

### TF2-10 🔴 Polylines still look mid-road on WIDE streets (offset magnitude, not direction)
- **Observed (Kevin, build 9):** center polylines still appear mid-street despite the TF2-5 rebuild.
- **Diagnosis (measured in shipped tiles):** E 2nd N/S sides are exactly 10.1m apart (2×5m) — the
  perpendicular offset IS applied and directionally correct. But CURB_OFFSET_METERS=5 from the
  CENTERLINE only reaches the curb on narrow side streets; on avenue-class streets (~20-25m
  curb-to-curb) 5m is still inside the traffic lanes → mid-road look. Magnitude, not direction.
- **Fix:** width-aware offset — backend-data to check whether osm_data.json carries lanes/width tags
  (preferred); else tier by street class (avenue/broadway/major-crosstown ≈ 9-10m, default ≈ 5-6m).
  Regen tiles (third rebuild — mechanical now). PWA cache bump + iOS build 10.
- **Status:** 🟢 FIXED (035c00c) → PWA live (cache v35) + iOS build 10. Verified: 2nd Ave sides 19.9m
  apart, E 2nd 11.4m. ⏳ Kevin visual confirm.

### TF2-9 🔴 Text overlay issue on the "Park here" sign-check sheet (build 9)
- **Observed (Kevin, build 9):** text overlay problem when tapping Park here (SignCheckConfirmView).
  Screenshot didn't reach the agent; likely the .medium-detent sheet clipping/overlapping its 5-item
  checklist + title + CTA, or drive-overlay text bleeding through the sheet material.
- **Status:** 🟢 MERGED #60 → build 10. ScrollView checklist + sticky CTA + opaque background +
  [.medium,.large] detents. ⏳ Kevin visual confirm.
- **Lands in:** iOS (`SignCheckConfirmView.swift`, ContentView sheet config).

### TF2-8 🔴 Cruise/destination entry zoom STILL bounces out (TF2-6 fix insufficient — async race confirmed)
- **Observed (Kevin, build 9, both modes incl. Penn Station destination):** zoom bounces IN then back
  OUT and stays out on drive-mode entry.
- **Root cause (now confirmed on-device):** MapKit `.follow` performs its zoom-to-default ASYNCHRONOUSLY
  when it acquires the user location — after our synchronous pitch+zoom setCamera. The TF2-6 order swap
  only fixed the synchronous sequence; the deferred follow animation still clobbers the tight zoom.
  The "re-apply guard" skipped in TF2-6 ("not needed empirically") IS needed — headless sim couldn't
  exercise the GPS-acquisition path.
- **Fix:** re-apply the drive camera (pitch + FT-8 altitude) AFTER follow's own move — hook
  `handleTrackingModeChanged(.follow)` and/or the first `regionDidChangeAnimated` post-engagement with
  a one-shot pending-reapply flag (no loops; setCamera cancels MapKit's in-flight animation). Verify
  with GPS-simulated motion in sim, not just launch.
- **Status:** 🟢 MERGED #60 → build 10. Re-apply hooked at regionDidChangeAnimated; per QA finding,
  the pending flag stays ARMED through altitude-neutral events (heading setCamera) and is only
  consumed by a real zoom-out; disarmed by user takeover/.none, exit, or 6s timeout. QA
  (`docs/qa/tf2-8-9-qa.md`) findings fixed in-branch. 516/0. ⏳ Kevin: entry-while-moving must end TIGHT.
- **Lands in:** iOS (ContentView tracking-mode handler + MapViewRepresentable).

### TF2-7 🔵 Cruise guidance hard to comprehend — simplify voice/text + "Park here" sign-check flow (UX/FEATURE)
- **Observed (Kevin, drive test):** zone-by-zone transitions (no-parking → metered → free along one
  block) make the free-parking callouts hard to follow while driving.
- **Kevin's direction:** (1) catch-all side-level summary — voice + bottom card say "free parking on
  the LEFT side" (not per-zone detail); explain it "might not be everywhere" (set expectations).
  (2) After stopping: a "Park here / Park my car" button → confirmation pop-up with a SIGN-CHECK
  checklist + novice education (check posted signs; fire hydrant 15ft rule; etc.). Note: ParkConfirmView
  ("Park here") + pin-drop flow already exist — integrate, don't duplicate.
- **Status:** 🟢 MERGED #59 → build 9. Side-level catch-all voice/card copy, aggregateSide (free ≥6m),
  Park-here → always-shown sign-check sheet → existing ParkConfirm flow. QA PASS-WITH-NOTES
  (`docs/qa/tf2-7-guidance-qa.md`); QA Finding #1 (due-north tie-break → one chip stuck '—') FIXED
  in-branch w/ signed-angle tiebreaker + regression test. 505/0. On-device voice/sheet feel = Kevin.
- **Lands in:** iOS (DrivingContextService commentary, DriveModeBottomCard, ParkConfirm flow).

### TF2-6 🔴 Cruise entry ZOOMS OUT (should zoom in) + buildings occlude at 45° pitch
- **Observed (Kevin):** entering Drive Mode → Find Parking nearby, the map zooms OUT instead of in to
  the current street. Also 3D buildings get in the way at the drive pitch, esp. when arrow/chevron off.
- **Root cause (zoom, confirmed):** `handleDriveModeAndCamera` applies pitch+zoom FIRST then engages
  `.follow` — MapKit's .follow engagement zooms to its own default altitude, overriding the FT-8 tight
  zoom. Recenter does the opposite (correct) order — tracking then zoom — which is why Recenter looks
  right but entry doesn't. Fix: swap order on entry (match recenter) + re-apply guard.
- **Buildings/pitch:** match Apple/Waze nav: `showsBuildings = false` during drive mode (flat in nav),
  consider pitch 45°→~30° (tunable). We already use their native .follow — these are tunables.
- **Status:** 🟢 MERGED #58 → build 9. Entry order swapped (tracking first, zoom last — matches
  Recenter), buildings OFF in drive, pitch 45°→30°. QA PASS-WITH-NOTES (`docs/qa/tf2-6-camera-qa.md`),
  480/0. On-device cruise-entry-ends-tight = Kevin.
- **Lands in:** iOS (`ContentView.handleDriveModeAndCamera` ordering, MapViewRepresentable drive config).

### TF2-5 🔴 Parking lines drawn in the MIDDLE of the road, not on the curb — SYSTEMIC (geometry)
- **Area:** Tile pipeline curb-offset geometry. `build/preprocess.js` `offsetPolyline`. Backend-data.
- **Observed (Kevin, throughout the map):** parking-regulation lines render in the middle of the road,
  not at real curb parking. (And TF2-4 wrong-side is the SAME root cause.)
- **Root cause (confirmed in code):** `offsetPolyline` uses a "Simple compass-based offset" — classifies
  each street as N/S or E/W (`|totalDLat|>|totalDLng|`) then offsets PURELY in lat or lng (cardinal).
  But the NYC grid is ROTATED (~29° for the numbered grid; East Village on its own skew). On any angled
  street a cardinal offset pushes the line DIAGONALLY relative to the road → lands mid-road or on the
  wrong curb. Offset magnitude 0.00004° (~4.4m) may also be too small for wide avenues.
- **Fix:** replace cardinal offset with a TRUE PERPENDICULAR offset — per-segment bearing → offset 90°
  to it (real street normal, lat/lng aspect-corrected) toward the curb for the side label. Subtle part:
  map side (N/S/E/W) → left/right of the segment's from→to direction. Systemic → FULL TILE REBUILD
  (~1028 files) — BUNDLE with the pending FT-11 oneway regen (one rebuild for both). Needs Kevin's
  approval for the rebuild (per docs/tile-geometry-investigation.md Q1 pattern).
- **Note:** separate from the earlier intersection-overshoot geometry issue (docs/tile-geometry-
  investigation.md, INTERSECTION_SETBACK_M) — could fix both in the same rebuild.
- **Status:** 🟢 FIXED — perpendicular street-normal offset (per-vertex bearing, mean-lat projection,
  dot-product side selection, CURB_OFFSET_METERS=5). Full tile rebuild committed (1254da5): ~1026 tiles,
  PWA + iOS bundle, +31919 oneway segments. PWA live (CACHE v34); iOS = build 8. ⏳ Kevin visual confirm
  (PWA now / iOS build 8): lines should hug the correct curb, not mid-road.

### TF2-4 🟡 School-zone wrong side — E 2nd St — likely RESOLVED by TF2-5 curb-offset rebuild
- **Area:** Tile data side/position correctness (same class as FT-9). Backend-data.
- **Observed (Kevin, on-device):** the red school-zone restriction on E 2nd St appears on the wrong
  side/position; "north side ... should be west side, not east side." Construction is on the east
  side but further down toward the block edge.
- **Probe:** EAST 2ND STREET has N (37) + S (35) side segments with rules in tiles. E 2nd runs E-W →
  N/S curbs (the "west/east side" wording is ambiguous: wrong-curb vs wrong-end-of-block — pending
  Kevin clarification + exact block between which avenues).
- **3 possible causes:** (a) NYC SOURCE data error (city sign dataset wrong side → fix is Tier 2
  community sign-correction, not pipeline); (b) pipeline side-assignment bug (systematic); (c) render
  offset (polyline on wrong side visually).
- **Status:** 🔴 open — NEED exact block (E 2nd between which aves) + side-vs-position clarification,
  then backend-data pulls the segment to determine cause.
- **Lands in:** backend-data (tiles) and/or iOS (render); or deferred to Tier 2 sign-corrections if
  it's a NYC source error.

### TF2-3 🟢 Arrow points the wrong way most of the time (esp. cruise / no-destination) — FIXED build 7
- **Area:** Drive Mode heading-up rotation. `MapViewRepresentable.syncDriveHeading` + LocationService heading source.
- **Observed (Kevin, on-device):** live location/heading "not good"; arrow points the WRONG way most of
  the time, especially in Drive Mode with NO destination (cruise/parking-hunt).
- **Root cause #1 (dominant): DOUBLE-ROTATION.** `syncDriveHeading` sets `camera.heading = h`
  (map rotates heading-up → travel = screen-up) AND rotates the puck view by the ABSOLUTE heading `h`.
  In a heading-up map the arrow should point straight up (0 rotation); rotating it by `h` too leaves it
  off by the map's heading. Only correct when h≈north. → "wrong most of the time."
- **Root cause #2 (why cruise is worse): STALE LOW-SPEED HEADING.** Parking-hunt speeds are often below
  `DRIVING_HEADING_MIN_SPEED_MPS = 1.8`, where GPS course is unreliable → heading freezes at last-good
  (FT-7 dropped the compass). Combined with #1, very visibly wrong while crawling. Destination mode masks
  it (route line gives orientation cue); cruise has none.
- **Fix:** (1) rotate the puck RELATIVE to camera heading (`h - camera.heading` ≈ 0 in heading-up mode;
  simplest: arrow points static-up while heading-up). (2) reduce low-speed staleness — lower the speed
  gate and/or smarter slow-speed heading. #31-sensitive path; RegionSyncGuard + live-UI gate.
- **Status:** 🟢 FIXED → build 7. Puck target = identity (arrow points up; map heading-up rotation does
  the work), speed gate 1.8→0.5 m/s (course-only, FT-7 intact), + FT-11 chevron `bearing-90`. QA
  PASS-WITH-NOTES (`docs/qa/build7-rotation-qa.md`), 479/0. On-device "arrow up / map turns under it"
  = Kevin's drive-test gate.
- **TF2-3-followup (small, next build):** lock `isRotateEnabled` (± pitch) OFF during Drive Mode so a
  manual rotation can't knock heading-up off (Apple/Waze nav behavior + FT-10 intent). QA flagged a
  transient self-correcting misdirection if user manually rotates mid-drive. Not blocking build 7.
- **Lands in:** iOS (`MapViewRepresentable.swift` puck rotation + makeUIView gesture flags, `LocationService` speed gate).

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
- **Status (2026-06-10):** 🟡 iOS DONE (picker + auto-derive + marker chevron), QA PASS-WITH-NOTES
  (`docs/qa/ft11-ios-qa.md`), 466/0, merged base to main. iOS works standalone (graceful fallback to
  picker when oneway data absent). ⚠️ QA Finding #1: chevron renders 90° off (chevron.forward points
  east; needs `bearing-90` correction) → BUNDLED into the build-7 TF2-3 rotation-fix pass.
  Backend tile fields (oneway/oneway_toward) staged on branch `data/ft11-oneway-tiles` — DEFERRED regen
  (run `node build/preprocess.js`, ~1027 files; + sw.js CACHE_VERSION bump for PWA).

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
