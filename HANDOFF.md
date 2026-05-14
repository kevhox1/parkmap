# WePark — Handoff

This document is the operating manual for any future Claude session working on WePark. **Read this first, then any spec doc in `docs/` for the feature in flight, then continue.** Don't reload chat history — the docs + git log are the source of truth.

## Session opening protocol

When Kevin starts a new session, default response:
> "Read `HANDOFF.md`, then `.claude/TEAM.md`, then `docs/<current-feature>.md`, then continue building."

Don't re-derive specs from chat memory. The docs are the source.

## Agent team (since 2026-05-07)

Work is divided across six specialized agents in `.claude/agents/`. See `.claude/TEAM.md` for the full operating manual — when to invoke each, parallelization rules, lifecycle of a feature, hand-off discipline.

| Role | File | Owns |
|---|---|---|
| Tech Lead / Planner | `.claude/agents/tech-lead.md` | Specs at `docs/<feature>.md` |
| iOS Engineer | `.claude/agents/ios-engineer.md` | All Swift / SwiftUI under `ios/` |
| PWA Maintainer | `.claude/agents/pwa-maintainer.md` | `index.html`, `sw.js`, `manifest.json` |
| Backend / Data | `.claude/agents/backend-data.md` | Supabase, `tiles/`, `scripts/` |
| Designer | `.claude/agents/designer.md` | Reviews at `docs/design/` (read-only on code) |
| QA / Verifier | `.claude/agents/qa-verifier.md` | Reports at `docs/qa/` (read-only on code) |

**Critical invariants:**
- QA is **never** the same agent that built the feature.
- Designer and QA are **read-only** on source — they file feedback, engineers act on it.
- Engineering agents on disjoint files **run in parallel** (single message, multiple Agent tool calls).
- Tech Lead writes specs, not code.

## Project Overview

WePark is **a community-driven parking app for NYC street parkers**. The product has three layers, in order of importance to the user:

1. **Parked-car management** (daily-active hook) — Smart Move, ASP-suspension banner, My Car pin, sign verification.
2. **Community** (the moat) — pseudonymous neighborhood chat per zone, structured tracker reports, reputation scoring.
3. **Drive Mode** (the in-car experience) — Apple-Maps-class navigation focused on free parking. Heading-up rotation, top turn ribbon, voice, parking-aware route selection, side-of-street green highlights. The biggest active investment.

**Distribution:** PWA (live at https://kevhox1.github.io/parkmap/) → **iOS native app** (form factor TBD — see "Open decisions"). Repo: https://github.com/kevhox1/parkmap.

## Current MVP roadmap (state-of-world)

**Shipped (PWA, live at `wepark-v30`):**
- ✅ Phase 1: PWA + tile-based map + ASP suspension banner
- ✅ Phase 2: Smart Score, Smart Move, My Car pin, Find Parking Near Me (one-way-aware coverage sweep)
- ✅ Phase 3: Threat Tracker UI (mock + Supabase-ready provider with connectivity probe)
- ✅ Self-healing service worker (auto-update on every push, no more manual cache-clearing)
- ✅ Email magic-link auth, pseudonymous username, `profiles` table
- ✅ SOHO/LES zone chat with Supabase Realtime + chat diagnostics button
- ✅ ASP suspension calendar (hardcoded 2026 — see fix note below)
- ✅ Drive Mode v3 full: Mapbox Search Box destination input, Mapbox Directions API, parking-aware alternative-route selection, top turn ribbon (Apple Maps green/blue/purple), turn-by-turn voice tiers, heading-up map rotation, re-routing on deviation, arrival prompt, nearby safe-blocks green overlay, iOS PWA safe-area insets

**Decided (2026-05-07):**
- ✅ **iOS launch form factor**: **Swift native, TestFlight distribution.** iOS-only initially; Android deferred. Estimated 8–16 weeks to TestFlight build at PWA parity. PWA continues to be the live product during the rewrite. Kevin's reasoning: "classic standard approach" — wants a polished launch and is OK with the longer build, accepts iOS-only for v1.

**Phase 5 progress (iOS Swift native build):**

Work-stream status as of 2026-05-11:

| Stream | Status | Notes |
|---|---|---|
| **W1a** — Xcode scaffold + module structure + tile bundle + ASP JSON + MapKit stub | ✅ merged (PR #12) | Project at `ios/WePark/WePark.xcodeproj`. Bundle ID `com.wepark.app`. iOS 17 min, iPhone-only, portrait-only. All 1,028 tiles + `asp-2026.json` bundled. **Resources land flat at app bundle root** — load via `Bundle.main.url(forResource:withExtension:)`, NOT constructed `/tiles/` subpaths. See `docs/ios-mvp-spec.md` §4.2 callout. |
| **W1.5** — Palette + visualization design spec | ✅ merged (PR #14) | `docs/design/ios-mvp-palette.md`. **Color encodes CURRENT STATE, not static category** (Option B). 4-color severity spectrum + neutral: red (restricted) → orange (free, restriction <24h) → amber-yellow `Color(red: 0.92, green: 0.76, blue: 0.0)` (metered active) → green (free, no restriction <24h) → gray.opacity(0.35) (unknown). |
| **W2** — Tile loader + colored polylines | ✅ merged (PR #13) | `Models/Segment.swift`, `Models/ParkingRule.swift`, `Models/Category.swift`, `Services/TileLoader.swift`. Coordinate order is `[lat, lng]` (visually verified). Stale-region race fixed via `currentRegion` property reading at Task execution time. *(Note: original SwiftUI `MapPolyline` rendering layer turned out to not scale — replaced in W4. See W4 row + `docs/ios-rendering-architecture-decision.md`.)* |
| **W3** — `ParkingRulesEngine` port + dynamic state color | ✅ merged (PR #15) | `Services/ParkingRulesEngine.swift`, `Services/ASPSuspensionService.swift`, `Services/StreetNameNormalizer.swift`, `Services/Date+ET.swift`, `Services/ParkingColors.swift`, plus `Models/SafetyLabel.swift`, `Models/NextRestriction.swift`, `Models/CurrentState.swift`, `Models/ASPSuspension.swift`. **All time math uses `Calendar.easternTime`** — zero `Calendar.current` use. 43 parity tests pass (all 5 R2 boundary cases covered). |
| **W4** — Block detail sheet + iOS rendering pivot | ✅ merged (PR #16) | `Views/BlockDetailView.swift` (sheet UI), `Views/MapViewRepresentable.swift` (UIKit bridge — new file, ~351 lines). **Mid-stream architecture pivot**: SwiftUI `MapPolyline` inside `@MapContentBuilder` did not scale to 40,664 segments — each polyline became ~30 Metal GPU resources, 1.22M total (25× over VectorKit's 50K threshold). Refactored to UIKit `MKMapView` via `UIViewRepresentable` + **5 `MKMultiPolyline` overlays grouped by `CurrentState` + 1 selected-block highlight overlay** per `docs/ios-rendering-architecture-decision.md`. **Memory: 19.92 GB → 137.5 MB (~145× reduction).** Tap handling: `MapReader.onTapGesture` → `UITapGestureRecognizer` on the `MKMapView`; haversine point-to-segment search preserved. **Tests: 43/0** — W4 did NOT add tests despite its PR description claiming a `testHP13_MonAfternoon_NextIsThursday_NotNextMonday`; the squash made zero changes to `ParkingRulesEngineParityTests.swift` (confirmed by W4.5 QA, see report). 2 W4 QA passes in `docs/qa/w4-pass-{1,2}-2026-05-11.md`. |
| **W4.5** — Color threshold (24h → 6h) | ✅ merged (PR #17) | `docs/ios-color-threshold-spec.md`. Single-constant change: `ParkingRulesEngine.nearFutureWindow` `24 * 3600` → `6 * 3600`. Defaults green-comfortably to the short-stay-visitor persona (Kevin's framing: "free for the next 6 hours = good for an errand"). 1 existing test flipped (`testCurrentState_ASP8hAway_FreeComfortably`, renamed from `_RestrictionComingSoon` because 8h is now past the threshold), 2 new boundary tests added (5.5h orange, 6.5h green). **Tests: 45/0.** Palette doc §1 / §2.1 / §2.2 / §7 + `ios-mvp-spec.md` §3.7 all updated. QA: `docs/qa/w4.5-pass-1-2026-05-11.md` (SHIP CLEAN after one cleanup commit). |
| **W5** — Pin drop + persistence | ✅ merged (PR #18) | `Models/ParkedCar.swift`, `Models/PinDropIntent.swift`, `Services/ParkPinService.swift`, `Views/ParkConfirmView.swift`, `Views/ParkedCarDetailView.swift`; `MapViewRepresentable.swift` + `ContentView.swift` + `BlockDetailView.swift` wired through. Long-press 0.4s OR "Park here →" button → `ParkConfirmView` sheet → confirm drops `mappin.circle.fill` blue pin at exact tap coordinate (no snap). Haversine-detected segment + up to 3 "Wrong street?" alternatives within 35m. `ParkPinService` exposes `firstPinDropped` (W6 hook) and `pinDropped` (W7.5 hook) Combine publishers. `UserDefaults`-backed single-pin silent-replace. Tap pin → `ParkedCarDetailView` with live `safetyLabel` + "I left" clear button. Spec: `docs/w5-pin-drop-spec.md`. QA: `docs/qa/w5-pass-1-2026-05-12.md` (SHIP WITH CAVEATS — 2 non-blocking findings queued for W5.1; tests 45/0). |
| **W5.1** — W5 polish (recenter button + QA fix-pass + SwiftUI warning fixes) | ✅ merged (PR #19) | `Services/LocationService.swift` (new — `@Observable` `CLLocationManager` wrapper publishing `userLocation`, `locationUpdateCount`, `isAuthorized`). Updates to `ContentView.swift` (find-me + find-my-car buttons; unified `ActiveSheet: Identifiable` enum collapsing W4's `BlockDetailView` + W5's `ParkConfirmView` + W5's `ParkedCarDetailView` into one `.sheet(item:)`), `MapViewRepresentable.swift` (`showsUserLocation = true` + `DispatchQueue.main.async` wraps on gesture / region callbacks), `Services/ParkPinService.swift` (moved `pinDropped.send` inside the do-catch per W5 QA Finding #1), `Views/ParkConfirmView.swift` + `Models/PinDropIntent.swift` (alternatives-list refreshes on selection per W5 QA Finding #2). **Also fixed** two runtime SwiftUI warnings Kevin caught in simulator smoke that QA's code review missed: "Modifying state during view update" (3 UIKit→SwiftUI callback sites wrapped in `DispatchQueue.main.async`) and "Currently, only presenting a single sheet is supported" (collapsed 3 `.sheet()` modifiers into one enum-driven). Tests: 45/0. QA: `docs/qa/w5-pass-1-2026-05-12.md` Pass-2 addendum (SHIP CLEAN). **`ActiveSheet` enum is the new extensibility point** — W6's notification rationale sheet attaches as a new `case`. |
| **W6** — Local notifications + permission flow | ✅ merged (PR #20) | `Services/NotificationScheduler.swift` (new), `Views/NotificationRationaleView.swift` (new), `Services/Constants.swift` modified. `WeParkApp.swift` registers `UNUserNotificationCenterDelegate` for tap routing. `ContentView` adds `.notificationRationale` case to the W5.1 `ActiveSheet` enum. Trigger: **`UNCalendarNotificationTrigger`** (DST-safe), NOT `UNTimeIntervalNotificationTrigger`. Identifier scheme `wepark.pin.<car.id>.r<rule_index>` for precise cancellation. **1-hour lead time** per `ios-mvp-spec.md` §2.1 locked baseline. Single notification per restriction window (no multi-stage). Deep-link tap routes through `notificationDeepLinkSubject` → `ActiveSheet.parkedCarDetail`. **Tests: 60/0** (+15 new W6 tests). QA: `docs/qa/w6-pass-1-2026-05-13.md` (SHIP CLEAN). One known polish gap — see W6.1 carry-over: tap-to-deep-link doesn't reliably present `ParkedCarDetailView` in simulator smoke; app foregrounds correctly but sheet presentation flakes. Unit tests verify the routing logic is correct; SwiftUI runtime presentation race needs follow-up. |
| **W7** — ASP banner + settings | ⏳ | Spec to be written. `ASPSuspensionService.suspensionState(at:)` API is already there for the banner to consume. Mute toggle in settings. **Consider bundling** Kevin's per-pin "remind me about this parking" toggle from W6 smoke feedback (currently a carry-over). |
| **W7.5** — "Park Until X" filter | 📋 queued (post-W7, pre-W8) | User picks a target end time ("I need this spot until 5pm"); blocks whose next restriction is past that time light up green. Waze / Google-Maps-style "arrive by" pattern. Tech-lead-recommended integration: after W5 pin drop, prompt "Parking until when?" — better discoverability than a standalone toolbar control. PWA already proves the concept (`renderParkUntilMode` at `index.html:4221`). Spec to be written by `@tech-lead` after W5 / W6 / W7 ship. See `docs/ios-color-threshold-spec.md` §8 for tech-lead's analysis (called Option F there). |
| **W8** — TestFlight build | ⏸️ blocked on Apple Developer Program | Enrollment still pending as of 2026-05-11. |

**Carry-over deferrals (not blocking next stream):**
- **Real-device memory + FPS measurement.** New memory acceptance criterion from W4 decision doc §5: peak simulator RSS < 500 MB after 5 min of Manhattan panning, zero Metal pruner assertions. Currently measured at 137.5 MB simulator RSS post-refactor. Real device measurement requires Apple Dev approval (W8 blocker). Replaces the older FPS-only R1 stress test which was never run and turned out to be the wrong proxy anyway.
- Live PWA-captured parity tests (W3 QA finding #3). Engine's `safetyLabel` strings are reasoning-checked; could diverge in subtle locale/format ways from real PWA output. Recommend a small "live snapshot" PR pre-W8.
- Tile resource folder reference (Xcode) vs synchronized group. Build time is no longer the binding constraint (the rendering bottleneck is fixed), so this is now a nice-to-have rather than a near-term need.
- W3 QA minor findings (#6, #7) — informational/deferrable cosmetic items.
- W4 QA pass-2 minor findings — see `docs/qa/w4-pass-2-2026-05-11.md`.
- W4.5 QA pass-1 nits (blank decision-log column in palette doc) — see `docs/qa/w4.5-pass-1-2026-05-11.md`. Cosmetic.
- W5 unit tests for `ParkPinService` round-trip + `findCandidateSegments` haversine — W5 QA Finding #3, optional. No regression risk; deferred. Worth doing during W6 or W7 if engineer has bandwidth.
- **Sign text truncation in `BlockDetailView` rule list.** Kevin caught during W5.1 smoke (2026-05-13): rule descriptions like `"NO PARKING 8AM-6PM EXCEPT SUNDAY METERED PARKING 30 MIN MAX"` truncate to `"NO PARKING 8AM-6PM EXCEP..."` with no way to read the full sign. Fix: make rule rows tap-expandable, or add a "show sign text" detail. Small UX add (~half engineer session). Owner: `@ios-engineer`. Good candidate to bundle with W6 or W7 polish.
- **Polyline intersection geometry artifacts** — addressed 2026-05-13 / 2026-05-14 via PR #21 (6m setback) and PR #22 (10m setback + butt line caps + iOS Resources sync). See `docs/tile-geometry-investigation.md` and `docs/qa/tile-intersection-clip-pass-{1,2}-2026-05-14.md`. Closed.
- **W6.1 — deep-link tap → ParkedCarDetailView presentation flake.** Kevin's W6 smoke confirmed: notifications schedule + fire + tap brings app to foreground correctly, BUT the `ParkedCarDetailView` sheet doesn't reliably present from the tap. Most likely a SwiftUI sheet-presentation race during the foreground transition (state-coordination issue with the `ActiveSheet` enum). 60 unit tests verify the routing logic, so user-impact mitigation is just one extra tap (user taps their pin → ParkedCarDetailView opens). Fix is post-merge polish, not a launch blocker. Owner: `@ios-engineer`. ~1 engineer session to investigate + fix.
- **Per-pin notification opt-in toggle.** Kevin's W6 feedback (2026-05-14): different parking sessions have different urgency (overnight = want reminder; 30-min meeting = don't bother). Current behavior is one-time iOS permission then notifications always schedule. Cleaner pattern: `ParkConfirmView` gets a `"Remind me before parking changes"` toggle (defaults ON). Quick-stop → flip off. Owner: `@ios-engineer`, bundle into W7 or W6.1 follow-up. ~half session.
- **Notifications for metered + other categories.** Currently `computeNextRestrictionHours` filters out METERED (so no "your meter expires" reminders) and other categories. Kevin asked about expanding (W6 smoke, 2026-05-14). Post-MVP — not a v1.0 priority since free parking is the core value prop. Owner: `@backend-data` + `@ios-engineer` co-design.
- **Degenerate sub-segments in tile data.** Per W6 / tile-PR-pass-2 QA: ~6.8% of segments (~2,670) have `line[0] === line[-1]` after the 10m setback (was 1.5% at 6m). Pre-existing data-quality issue in `extractSubSegment` where sub-zones near intersection edges collapse to a point under aggressive trimming. Renders as invisible / no impact, just wasted bytes. Owner: `@backend-data` — small fix to add a degenerate-skip filter in the sub-segment emission loop. Not urgent.
- **SW cache bump** for the merged tile changes (PR #21 + PR #22). `sw.js` `CACHE_VERSION` `wepark-v32` → `wepark-v33`. Owner: `@pwa-maintainer` post-merge. Without it, PWA clients will serve cached W1a-era tiles indefinitely. **Pending now.**
- **VoiceOver swipe-through-blocks on the map** (not in the sheet) — dropped in W4 fix-pass-1 (Option A from decision doc): the `Annotation` per segment was unscalable. In-sheet a11y is fully intact. Post-MVP: lightweight `MKAnnotation` at reduced density is the proper path.

**Open decisions (waiting on Kevin):**
- 🤔 **NYC 311 real-time API for snow emergencies**: blocked by CORS in browser. Two paths: (a) Cloudflare Worker proxy (~15 min setup, free), or (b) skip until iOS native (no CORS, direct fetch works). Currently leaning (b) — and now that Swift native is decided, this naturally falls out for free in the Swift port.
- 🤔 **Supabase tracker schema**: `SUPABASE_MVP_SCHEMA.md` defines tracker tables/RPCs but NOT yet applied. Required before flipping `tracker-config.js` provider from `'mock'` to `'supabase'` and enabling cross-pollination.

**Drive-test pending:**
- 🚗 Kevin needs to take Drive Mode v3 out for a real Manhattan drive with phone mounted on dashboard. Voice timing, rotation smoothness, ribbon legibility while driving, side-highlight density — all need real-world feedback.

**Backlog (ordered by priority):**
- **Phase 2d**: Cross-pollination — tracker reports auto-post to zone chat as `system_tracker` messages. Requires `SUPABASE_MVP_SCHEMA.md` applied + provider flipped to `'supabase'`.
- **Phase 2e**: Reputation scoring (+/− on confirms/retracts). Schema field `profiles.reputation` already exists.
- **Phase 3 polish**: Local "move your car" notifications via Web Notifications API.
- **Phase 4a**: "Generate QR code for my zone" — cold-start distribution per Kevin's "stickers on windshields" idea.
- **Phase 4b**: First-time user landing page with seeded zone preview.
- **Phase 5**: iOS launch — **Swift native + TestFlight** (decided 2026-05-07; in active development since 2026-05-08). MVP streams W1a, W1.5, W2, W3, **W4, W4.5, W5, W5.1, W6** are merged to `main`, plus 2 tile-data PRs (#21 + #22) addressing the intersection-overshoot artifact. See "Phase 5 progress" table above for stream status. Next stream: **W7** (ASP banner + settings — spec to be written). After: W7 → W7.5 ("Park Until X" filter) → W8 (TF1, blocked on Apple Dev approval) → W8.5 (Drive Mode, vision-focused port per `docs/drive-mode-scope-spec.md`) → W9 (TF2). v1.0 App Store launch ships with Drive Mode included. Post-MVP follow-on phases: threat tracker UI, zone chat, Smart Move recommendations, address search, snow emergency / NYC 311 API, paywall + StoreKit (see `docs/business-model.md`).
- **2027 ASP calendar refresh**: hardcoded 2026 calendar in `loadASPSuspensions()` will need annual update each Dec/Jan when NYC publishes the new PDF. OR wire NYC 311 API once on native.

## Live infrastructure

- **GitHub Pages:** https://kevhox1.github.io/parkmap (auto-deploys on push to `main`).
- **Supabase project:** `https://jiispshyqerscdoferaw.supabase.co` (created 2026-04-22, free tier).
  - Tables: `profiles`, `zones`, `zone_messages` (chat schema applied via `supabase/01-mvp-schema.sql`).
  - **Tracker tables NOT yet applied** — `SUPABASE_MVP_SCHEMA.md` is the spec; runs in SQL editor when ready.
  - Realtime publication includes `zone_messages`.
  - Auth Site URL: `https://kevhox1.github.io/parkmap/`. Email magic-link auth enabled.
- **Tracker provider:** still `'mock'` (localStorage). Flip to `'supabase'` after applying tracker schema.
- **Mapbox token (Drive Mode v3):** shipped in `tracker-config.js` as `mapboxToken` — single shared token. Created 2026-05-01, public `pk.*`, URL-restricted at Mapbox to `kevhox1.github.io` + `localhost:8765`. Kevin disabled GitHub Push Protection on this repo to allow the `pk.*` token (it false-positives Mapbox public tokens). `localStorage.wepark_mapbox_token` works as a power-user override but isn't normal flow.
- **NYC 311 API:** keys created 2026-05-01 but **NOT used in the app** due to browser CORS. Keys live with Kevin (1Password etc.). Will be wired directly when iOS native lands (no CORS in native HTTP). Endpoint: `https://api.nyc.gov/public/api/GetCalendar?fromdate=YYYY-MM-DD&todate=YYYY-MM-DD` with header `Ocp-Apim-Subscription-Key`. Response shape: `{ days: [{ today_id: 'YYYYMMDD', items: [{ type: 'Alternate Side Parking', status: 'IN EFFECT' | 'SUSPENDED', details }] }] }`.
- **ASP suspension data:** hardcoded 2026 calendar in `index.html` (`ASP_SUSPENSIONS_2026` constant — 42 dates from official NYC DOT PDF). Powers `aspSuspensions` map → `isASPSuspended()` → `computeNextRestrictionHours()` → `actionableSafetyLabel()` → green highlights + "Free until X" labels + suspension banner. Snow emergencies NOT covered until NYC 311 API wired (post-native). *(Earlier docs said "41 dates" — that was a counting error. Verified 42 via direct count of `index.html`:2031–2072 on 2026-05-10.)*

## How to work in this repo

- **Two codebases under one repo.**
  - **PWA** (the live product, maintenance mode): `index.html` + `sw.js` + `manifest.json` + `tracker-config.js` at repo root. Owned by `@pwa-maintainer`.
  - **iOS app** (active investment): everything under `ios/WePark/`. Owned by `@ios-engineer`. Xcode project at `ios/WePark/WePark.xcodeproj`; source files at `ios/WePark/WePark/{Models,Views,Services,Resources}/`; tests at `ios/WePark/WeParkTests/`. **Resources land flat at app bundle root at build time** — `Bundle.main.url(forResource:withExtension:)` is the correct loading API, NEVER construct `bundle/tiles/X.json` paths. See `docs/ios-mvp-spec.md` §4.2 callout (born from W1a QA finding #1).
  - Shared between both: `tiles/` (the data — see below), `docs/` (specs + design + QA reports).
- **Single-file architecture (PWA).** `index.html` contains the HTML, CSS, and all application JS. Don't split it into modules without an explicit conversation with Kevin. The file is ~186KB and that's fine.
- **Service worker cache version must be bumped on every asset change.** Edit `CACHE_VERSION` at the top of `sw.js` AND `APP_VERSION` in index.html (currently both `wepark-v30`). The two should match — the page compares them to detect updates and auto-reload. SW now self-heals: on activation it broadcasts to all clients which auto-reload to pick up fresh code. No more manual cache-clearing. Without a bump, users get stale versions via the cache-first strategy on tiles and stale static assets on intermittent network.
- **Tile data is pre-built and committed.** Current state (post-PR-#22, 2026-05-14): **1,027 tiles, 39,370 segments**, ~24 MB on disk. `tiles/index.json` for current totals. Don't regenerate unless Kevin has changed upstream NYC source data or the tiling algorithm — regeneration is expensive and the churn is large (~1,000-file diff per rebuild). `build/preprocess.js` fetches live NYC Socrata sign data on every run, so consecutive runs will show small segment-count drift even without algorithm changes — flag in PRs to distinguish intentional algorithm churn from data drift. *(Earlier counts: W1a baseline `1028 / 40664`; PR #21 with 6m setback `1029 / 40121`; PR #22 with 10m setback `1027 / 39370`.)*
- **⚠️ Tile data lives in TWO paths.** Discovered 2026-05-14 the hard way. The build script writes to:
  1. `./tiles/` (repo root) — what the **PWA** reads via `fetch('/tiles/...')`
  2. `./ios/WePark/WePark/Resources/tiles/` — what the **iOS app** bundles into `WePark.app` and reads via `Bundle.main.url(forResource:...)`
  `build/preprocess.js` MUST write to both (handled automatically since PR #22 added the `IOS_TILES_DIR` sync block). **For 5 days / 4 PRs prior to that fix, only path #1 was updated and iOS users were running W1a-era stale tiles invisibly.** Any future tile-data PR should show diff hunks in BOTH paths; if only one is touched, the iOS app will silently run stale data. QA process change: for data-pipeline PRs, verify the consumer read path is updated, not just the writer.
- **No automated test suite exists.** QA is done via:
  - Independent QA subagent review (see `TRACKER_QA_VERIFY.md` for the pattern)
  - Manual smoke on the live site after deploy
  - Code review in PRs
  Never let the agent that built a feature also sign off on it — spawn a separate QA subagent.
- **Deploy target: GitHub Pages, auto-deploy on push to `main`.** There is no build step. `.nojekyll` is present so GitHub Pages serves files as-is.
- **Specs live at the repo root and `docs/`.** Key docs:
  - `PROJECT.md` — current status, phase checklist
  - `PRODUCT.md` — product vision
  - `docs/ios-mvp-spec.md` — iOS MVP TestFlight build spec. All §3 decisions locked. §3.7 reframed around **Option B (dynamic state color)** as of 2026-05-10. **§3.7 + §7 R1 are SUPERSEDED 2026-05-11 by `docs/ios-rendering-architecture-decision.md`** — the rendering layer is now UIKit `MKMapView` + 6 `MKMultiPolyline` overlays, not SwiftUI `MapPolyline` per segment. Read decision doc before touching anything map-rendering-related.
  - `docs/ios-rendering-architecture-decision.md` — **load-bearing** rendering architecture decision (2026-05-11). Why SwiftUI `MapPolyline` didn't scale (1.22M Metal resources at 40k segments, 25× over VectorKit's 50K limit). How the UIKit bridge works. §5 defines the new memory acceptance criterion (peak simulator RSS < 500 MB, zero Metal pruner assertions) — replaces W2 spec §7 R1 (FPS-only). Read before W4.5 / W5 work.
  - `docs/design/ios-mvp-palette.md` — palette + visualization spec produced in W1.5. Defines the 4-color severity spectrum, `ParkingColors` enum constants, and ASP banner spec. **§4 rendering styling is partially superseded by the rendering decision doc** — the `MapPolyline` styling examples no longer apply; the `MKMultiPolyline` overlay grouping is the live pattern.
  - `docs/ios-color-threshold-spec.md` — W4.5 spec (now merged via PR #17). Lowered `nearFutureWindow` from 24h to 6h. §8 contains tech-lead's analysis of Option F ("Park Until X" filter) which became W7.5.
  - `docs/qa/` — independent QA reports per W-series stream (W1a, W2, W3 each have a `*-pass-1-*.md`; W4 has both `w4-pass-1-2026-05-11.md` and `w4-pass-2-2026-05-11.md`). Read the latest before merging anything in that work stream's neighborhood; it documents subtle gotchas (flat-bundle layout, ASP_DAILY day-mask bug fix, overlay Z-order, `DispatchQueue.main.async` in `regionDidChangeAnimated`, etc.).
  - `docs/business-model.md` — revenue strategy (Free + WePark Pro, $4.99/mo or $29.99/yr, 7-day trial). **MVP ships free**; paywall + StoreKit land in v1.1 post-validation. DO NOT build StoreKit into MVP scope.
  - `TRACKER_MVP_SPEC.md` — tracker feature spec (read before touching tracker code)
  - `SUPABASE_MVP_SCHEMA.md` — backend tables + RPC functions (the Supabase provider in `index.html` calls the RPC names defined here)
  - `BACKEND_OPTIONS.md` — backend trade-off notes
  - `TRACKER_QA_PASS_2.md` — latest independent QA verification (2026-04-17, against `main` post PR #5/#6). Supersedes the earlier `TRACKER_QA_VERIFY.md` (dated 2026-04-07, pre-PR-#6), which is retained for history only.
- **Branch and PR conventions.**
  - Work on a topic branch off `main`, never push to `main` directly (except docs/PROJECT/handoff updates and SW cache bumps).
  - PR titles follow Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `style:`.
  - Merges to `main` are **squash merges** via `gh pr merge <n> --squash --delete-branch`. The squashed commit ends with ` (#N)`.
  - Separate `chore: bump SW cache to vN` commits are OK and have happened historically.

## Tech stack

- **Frontend:** vanilla JS in a single `index.html`, Leaflet 1.9.4 (loaded from unpkg CDN)
- **PWA:** `manifest.json` + `sw.js` service worker with separate static/tile caches
- **Backend (in progress):** Supabase (Postgres + PostgREST + Realtime + Anonymous Auth). Provider is loaded dynamically as an ESM import from jsdelivr when `tracker-config.js` is set to `provider: 'supabase'`.
- **Tracker provider config:** `tracker-config.js` at repo root — empty creds by default, falls back to local mock
- **Hosting:** GitHub Pages, auto-deploy on push to `main`
- **Data sources:** NYC parking sign data (merged ASP + main), pre-tiled into 1,028 JSON tiles under `tiles/` (~27 MB on disk)

## Build time / hardware note (iOS)

`xcodebuild` clean builds of the iOS app are slow on memory-constrained machines (8 GB RAM observed at 10–15 min). The bundled 1,028 tile JSONs are processed as individual file copies under Xcode 16's `PBXFileSystemSynchronizedRootGroup`. On a 16 GB+ Mac, clean builds drop to 2–3 min and incremental builds to seconds. Folder-reference refactor (see "Carry-over deferrals" above) would also help. If a session reports slow builds, suggest: (a) close Chrome/Spotify/OneDrive/heavy apps, (b) Cmd+. between runs to release the running app's 1.8GB, (c) Cmd+R not Cmd+Shift+K+R (don't clean every time), (d) hardware upgrade to 16 GB long-term.

## Changelog

### 2026-05-14 — W6 (notifications) ships + tile intersection artifact fix saga + iOS dual-path bug discovered & fixed

Marathon day. W6 (local notifications) shipped, and the polyline intersection-overshoot artifact got two iterative tile-data fixes — the second of which surfaced a **5-day-old structural bug** that meant zero of the tile-data PRs since W1a had actually reached iOS users.

- **PR #20 (W6 — local notifications + permission flow)** merged as squash commit `3346a97`. `Services/NotificationScheduler.swift` (new), `Views/NotificationRationaleView.swift` (new). `WeParkApp` registers `UNUserNotificationCenterDelegate`. `ContentView` extends the W5.1 `ActiveSheet` enum with `.notificationRationale`. **`UNCalendarNotificationTrigger`** (DST-safe), identifier scheme `wepark.pin.<car.id>.r<rule_index>`, 1-hour lead time per `ios-mvp-spec.md` §2.1. Tests: 60/0 (+15 W6 tests). QA: `docs/qa/w6-pass-1-2026-05-13.md` (SHIP CLEAN). Kevin's smoke verified rationale-sheet → permission → schedule → cancellation. **One known polish gap (W6.1 carry-over):** deep-link tap reliably foregrounds the app but doesn't always present `ParkedCarDetailView` — SwiftUI sheet-presentation race during foreground transition. Unit tests verify routing logic is correct.

- **PR #21 (tile intersection clip — 6m setback)** merged as squash commit `2a3dcba`. First iteration of the intersection-overshoot fix. Added `INTERSECTION_SETBACK_M = 6` constant to `build/preprocess.js`, regenerated all 1,028 tiles. **But this PR's tile changes only landed in `./tiles/` (PWA path), not in `./ios/WePark/WePark/Resources/tiles/` (iOS bundle path).** Nobody realized the iOS app was running W1a-era stale tiles. QA reviewed the diff cleanly because the diff was internally consistent — they didn't trace the consumer read paths.

- **PR #22 (10m setback + butt line caps + iOS Resources sync)** merged as squash commit `fa32ff9`. Kevin tested PR #21 in simulator: visual artifact still bad. Bumped the setback from 6m to 10m. Changed `MKMultiPolylineRenderer.lineCap` from `.round` to `.butt` to eliminate round-cap visual bleed. **Then discovered the dual-path bug while debugging "why aren't the changes showing":** simulator log said `1028 tiles, 40664 segments` (W1a baseline) when disk said `1027 / 39370` (current). Investigation: `build/preprocess.js` wrote to `./tiles/` only; iOS Xcode bundle copies from `./ios/WePark/WePark/Resources/tiles/` — a separate, never-synced copy. Fixed with `IOS_TILES_DIR` constant + sync block in the build script. Regenerated all tiles into BOTH paths in one commit. QA: `docs/qa/tile-intersection-clip-pass-2-2026-05-14.md`. Kevin's post-clean-rebuild visual smoke confirmed clean intersections. One pre-existing non-blocking finding: ~6.8% of segments are now degenerate (start==end) due to the more aggressive trim; renders as nothing, queued for `@backend-data` cleanup.

- **The dual-path lesson.** `HANDOFF.md` now has a structural callout documenting that tile data lives in TWO paths and the build script must write to both. QA process change documented: for data-pipeline PRs, verify the **consumer read path** is updated, not just the emitter. A `grep -r "Bundle.main.url" ios/` during QA on PR #21 would have surfaced the iOS reader and prompted "where does Xcode pull this resource from?" — that didn't happen, and we ate 5 days of silent failure. Both QA agents and the orchestrator (me) missed it.

- **W6 carry-overs landed:**
  - W6.1 (deep-link presentation flake) → fix-pass needed; non-blocking.
  - Per-pin notification toggle (Kevin's UX idea: ParkConfirmView gets a "Remind me" switch) → bundle with W7 or W6.1.
  - Notifications for METERED + other categories → post-MVP.
  - `sw.js` `CACHE_VERSION` bump (`wepark-v32` → `wepark-v33`) → `@pwa-maintainer` post-merge follow-up. **Pending now.**

- **Project-level allowlist added.** Created `.claude/settings.json` with `Bash(xcodebuild *)` allowlisted to reduce permission prompts during agent work. Generated via the `fewer-permission-prompts` skill from analyzing recent transcripts.

### 2026-05-13 (continued) — W5.1 ships (recenter buttons + SwiftUI runtime fixes)

W5.1 shipped the same day as W5. Originally scoped as a small polish PR (recenter button + 2 QA fix-pass items from W5 pass-1), it surfaced **two additional SwiftUI runtime bugs** during Kevin's simulator smoke that code-review QA had missed.

- **PR #19 merged** as squash commit `bab4bb5`. Two source commits squashed: `7d3f019` (recenter + QA fix-pass) + `cd6297d` (SwiftUI runtime fixes).
- **New file:** `Services/LocationService.swift` (~80 lines) — `@Observable` `CLLocationManager` wrapper requesting `.whenInUse` permission, publishing `userLocation: CLLocationCoordinate2D?` + `locationUpdateCount: Int` (counter sidesteps `CLLocationCoordinate2D` not being `Equatable` for `.onChange`) + `isAuthorized: Bool`.
- **Find-me + find-my-car buttons** stacked top-right of map. `location.fill` always visible; `car.fill` only visible when `ParkPinService.parkedCar != nil`. Tap recenters via `setRegion(... 400m span ...)` with animation.
- **`ActiveSheet: Identifiable` enum** introduced — unifies W4/W5's three previously-separate `.sheet(item:)` modifiers into one. Cases: `.blockDetail(Segment)`, `.parkConfirm(PinDropIntent)`, `.parkedCarDetail(ParkedCar)`. Single `@State activeSheet: ActiveSheet?` drives presentation. `selectedSegmentID` kept independent for the W4 map highlight overlay. **This is the new extensibility point for W6/W7's sheets — add a new enum case, done.**
- **`pinDropped.send(car)` moved inside the do-catch block** in `ParkPinService.save()` (W5 QA Finding #1).
- **Alternatives list refreshes after "Wrong street?" selection** so the just-selected block no longer appears as an alternative; the previously-detected block takes its place in the list (W5 QA Finding #2).
- **SwiftUI runtime warnings Kevin caught in simulator smoke** that code-review QA missed:
  - *"Modifying state during view update, this will cause undefined behavior."* fired 4× — 3 UIKit→SwiftUI callback sites (`regionDidChangeAnimated`, `handleTap`/`handleLongPress`, `LocationService` delegate methods) writing `@Binding` / `@Observable` properties synchronously during a SwiftUI render. **Fixed** by wrapping all sites in `DispatchQueue.main.async { [weak self] in ... }`.
  - *"Currently, only presenting a single sheet is supported."* fired 3× — three separate `.sheet()` modifiers chained on the same `ZStack`. SwiftUI rendered only the first; the W5 QA agent's code-review assumption that they were "on distinct views" was wrong. **Fixed** via the `ActiveSheet` enum collapse above.
- **QA Pass-2 addendum** in `docs/qa/w5-pass-1-2026-05-12.md` — verified both runtime fixes via `git diff 7d3f019..cd6297d`, confirmed `[weak self]` patterns + value-snapshot captures + no missed mutation sites. Final verdict SHIP CLEAN.
- **Kevin's W5.1-discovered observation: sign-text truncation in `BlockDetailView` rule rows.** `"NO PARKING 8AM-6PM EXCEPT SUNDAY..."` cuts to `"NO PARKING 8AM-6PM EXCEP..."` with no read-the-full-sign affordance. Added to backlog as a small W6/W7 polish bundling candidate.

**Lesson learned: code-review QA misses runtime warnings.** The pattern of "QA verifies in code without running the simulator → engineer pushes → Kevin catches in console → fix-pass" is now happening on both W4 and W5/W5.1. Worth a future QA-agent-prompt revision: include `xcodebuild test`-output-check + a runtime-warning-string scan if simulator can launch. (Captured here for next-time application.)

### 2026-05-13 — W5 ships (pin drop) + W5.1 queued + Drive Mode scope locked

W5 shipped — Kevin can now drop a parked-car pin on the map, persist it across launches, and tap it to see live parking rules. Mid-day Drive Mode scope decision also locked (Option E phased rollout, TF2).

- **PR #18 — W5 (pin drop + persistence)** merged as squash commit `8099636`. 1099 LOC across 8 files. New: `Models/ParkedCar.swift`, `Models/PinDropIntent.swift`, `Services/ParkPinService.swift`, `Views/ParkConfirmView.swift`, `Views/ParkedCarDetailView.swift`. Updated: `MapViewRepresentable.swift` (added `UILongPressGestureRecognizer` at 0.4s, car-pin annotation rendering, tap disambiguation), `ContentView.swift` (full integration: `ParkPinService`, `pinDropIntent`, three `.sheet(item:)` bindings, `findCandidateSegments`), `BlockDetailView.swift` (W4 "Park here →" button no longer disabled).
- **Spec at `docs/w5-pin-drop-spec.md`** (locked 2026-05-12). Two OQs resolved at the top: port "Wrong street?" alternatives = **yes**, side prompt = **no, auto-detect from `segment.side`**.
- **Hooks for W6 + W7.5 in place.** `ParkPinService.firstPinDropped: PassthroughSubject<Void, Never>` (one-time event for first-ever pin) and `pinDropped: PassthroughSubject<ParkedCar, Never>` (every pin). W6 attaches to firstPinDropped to gate the notification rationale sheet. W7.5 attaches to pinDropped to prompt "Parking until when?".
- **Pin behavior preserves PWA's 2026-04-22 "no snap" refinement** — pin stays at exact tap coord, detected segment is for rules-lookup only.
- **QA: `docs/qa/w5-pass-1-2026-05-12.md`** (SHIP WITH CAVEATS). Two non-blocking findings folded into W5.1 scope.
- **W5.1 queued** as the next stream — bundles (1) Kevin's recenter / find-me button feature request (he got "lost" zooming out during W5 smoke and ended up staring at his pin in NY Harbor with no easy way back), (2) move `pinDropped.send` inside the do-catch in `ParkPinService.save()` (QA Finding #1, must land before W7.5), (3) refresh `alternativeCandidates` after a "Wrong street?" selection so the chosen block doesn't still appear as an alternative (QA Finding #2). Small PR, ~half engineer session.
- **Drive Mode scope spec locked earlier same day** at `docs/drive-mode-scope-spec.md`. **Option E (phased)**: TF1 ships without Drive Mode (W5 + W6 + W7 + W7.5), TF2 adds vision-focused Drive Mode (Option B scope). Vision quote captured from Kevin: *"Free parking on the right, free parking on the left until x, y, z... a lot of fear about where a person should park. I'm hoping that this app clarifies that fear for them."* Routing = Mapbox HTTP-only (NOT the iOS SDK — its free tier is 100 MAU / 1k trips/month; the HTTP API is 100k req/month). Parking-aware route scoring is required in v1.0. Kevin had already drive-tested the PWA Drive Mode v3 and found it poor (GPS jitter, invisible one-way directions, lag, dashboard display issues) — these findings are captured in `docs/drive-mode-scope-spec.md` §11 and shape the eventual W8.5 spec.
- **Carry-over additions:** polyline intersection geometry artifacts (Kevin flagged during W5 smoke — pre-existing in tile data, owned by `@backend-data`).

### 2026-05-11 — W4 ships; iOS rendering architecture pivot (UIKit MKMapView)

Massive day. W4 (block detail sheet on tap) shipped as PR #16 after a mid-stream architecture pivot that re-baselined the iOS app's polyline rendering layer.

- **PR #16 merged** as squash commit `c713241`. 5 source commits squashed: initial W4 build + fix-pass-1 (a11y + dismiss bugs) + **rendering refactor** + fix-pass-2 (overlay Z-order + DispatchQueue.main.async threading; engineer claimed a new HP-13 test but the squash made zero changes to `ParkingRulesEngineParityTests.swift` — confirmed by W4.5 QA) + a11y sort-priority. Branch `ios/w4-block-detail` deleted.
- **The pivot — discovered by measurement, not code review.** While verifying W4 fix-pass-1 in the simulator, Activity Monitor showed **WePark process RSS at 19.92 GB**. Xcode console produced the assertion: `Exceeded Metal Buffer threshold of 50000 with a count of 1262055 resources` from `VectorKit_Sim/MDMapEngine.mm:2616`. Root cause: SwiftUI `MapPolyline` inside `@MapContentBuilder` does NOT scale to 40k segments — MapKit lowers each polyline into ~30 Metal GPU resources, and at 40,664 segments that's 1.22M resources, 25× over VectorKit's internal 50K pruner threshold. **W3 had this bug too; nobody had measured.** The W4 Annotation a11y overlay was an aggravator but not the root cause.
- **`@tech-lead` dispatched, produced `docs/ios-rendering-architecture-decision.md`** — binding decision: **Option 1**, UIKit `MKMapView` wrapped via `UIViewRepresentable` + **5 `MKMultiPolyline` overlays grouped by `CurrentState`** (freeComfortably, freeButRestrictionSoon, meteredActive, restrictedNow, unknown) + 1 separate selected-block highlight overlay. Collapses 40,664 individual Metal resources into 6 resource groups.
- **`@ios-engineer` implemented (commit `aacf8b7`).** New file `ios/WePark/WePark/Views/MapViewRepresentable.swift` (~351 lines). `ContentView` rendering layer replaced. Sheet UI, tap handling (`MapReader.onTapGesture` → `UITapGestureRecognizer` on `MKMapView`; haversine point-to-segment search preserved verbatim), engine wiring all preserved. `TileLoader.maxCachedTiles` raised 50 → 200 (undersized LRU cap from fix-pass-1 was a contributor to "only upper Manhattan rendered" symptom). **Memory: 19.92 GB → 137.5 MB (~145× reduction).** Zero Metal pruner assertions post-refactor.
- **Notable mid-stream "is the engine broken?" diagnosis (debunked).** Kevin observed a Mott St ASP_MON_THU block on Monday May 11 PM returning `"Free until Monday 9:30 AM"` (next Monday, ~163h) instead of Thursday (~67h). Smelled like an engine regression. Engineer checked: `git diff` confirmed `ParkingRulesEngine.swift` untouched in the rendering refactor. The label is **correct**: Thursday May 14, 2026 is the Solemnity of the Ascension, which is in `asp-2026.json` as an ASP-suspension date. The 14-day walker correctly skips Thursday → finds Monday May 18. The PWA returns the same. Engineer's fix-pass-2 report claimed they added a new test `testHP13_MonAfternoon_NextIsThursday_NotNextMonday` for the non-suspended Thursday-finding path — but the squash made zero changes to the test file. The test was either dropped between local work and the push, or never written. Either way, the documenting test never actually landed. W4.5 added equivalent threshold-boundary coverage instead.
- **Two QA passes.** `docs/qa/w4-pass-1-2026-05-11.md` against `254ef36` (SHIP WITH CAVEATS — flagged a11y first-focusable element, dismissSheet content blanking, Annotation overlay overhead). `docs/qa/w4-pass-2-2026-05-11.md` against `3c46511` (SHIP WITH CAVEATS — pass-1 a11y fix was only half-fixed; ✕ close button still preceded safety label in VoiceOver source order). Final commit `3eeb6e4` added `.accessibilitySortPriority(1)` to safety label and `.accessibilitySortPriority(0)` to close button.
- **`@tech-lead` also produced `docs/ios-color-threshold-spec.md`** (W4.5). Recommendation: lower `nearFutureWindow` from 24h to 6h to default the green-comfortably semantic to the short-stay-visitor persona. Surfaced when Kevin noted that an ASP block with cleaning in 5 hours should read as green ("I'll be gone by then") not orange ("warning").
- **W4.5 shipped as PR #17 (squash commit `ebeed38`)** later the same day. One-constant change (`nearFutureWindow` 24h → 6h), 1 test flipped (`testCurrentState_ASP8hAway_FreeComfortably` — 8h is now past the threshold), 2 new boundary tests at 5.5h / 6.5h. **Tests: 43 → 45/0.** Palette doc §1 / §2.1 / §2.2 / §7 + `ios-mvp-spec.md` §3.7 all updated. QA: `docs/qa/w4.5-pass-1-2026-05-11.md`, SHIP CLEAN after one palette-doc cleanup commit (engineer initially missed 2 stale "24h" references outside the spec's §7 change-list).
- **Kevin's "free until X" intuition surfaced during W4.5 discussion** spawned tech-lead's **§8 analysis (Option F)** in the threshold spec. Verdict: real and valuable feature — the PWA already has it at `renderParkUntilMode` in `index.html:4221` — but 3-4× the scope of the threshold change with unresolved design questions (does the filter REPLACE the dynamic state engine or LAYER over it?). **Queued as W7.5** for after W5 ships, with recommended integration through the pin-drop workflow ("Parking until when?" prompt) for better discoverability than a standalone toolbar.
- **Test-count factual correction.** The W4 PR description and the original W4 fix-pass-2 engineer report both claimed a new test `testHP13_MonAfternoon_NextIsThursday_NotNextMonday`. The W4 squash made **zero changes** to `ParkingRulesEngineParityTests.swift` — the test was either dropped between local work and push, or never written. W4.5 QA pass independently verified via `git show c713241` that the test file is unchanged from W3. Test count after W4 was 43/0, not 44/0 — corrected in the Phase 5 table above.
- **Lessons learned & spec gap closed.** The pre-2026-05-11 specs at `docs/ios-mvp-spec.md` §3.7 and palette doc §4 implicitly assumed SwiftUI `MapPolyline` would scale — never load-tested. §7 R1 stress test was FPS-only, never run. Both gaps closed by `docs/ios-rendering-architecture-decision.md` §5: **new acceptance criterion** = peak simulator RSS < 500 MB after 5 min of Manhattan panning, zero Metal pruner assertions. Real-device measurement still pending Apple Dev approval.
- **W5 onward unblocked.** Pin drop, notifications, ASP banner all sit above the rendering layer — none of them need to be revisited.

### 2026-05-10 (late evening) — New dev machine setup + W4 spec locked + W3 followups debunked

Tonight's session was a Mac migration and pre-W4 setup pass. No code merged to `main`; two doc commits.

- **New dev machine.** Kevin moved from his 8 GB Mac (which had clean-build times of 10–15 min per the "Build time / hardware note" section above) to a 16 GB Mac. Repo cloned fresh at **`/Users/kevinhoxha/repos/parkmap`** (not `~/Documents/WePark` — that's the stale prior-machine checkout). Xcode 26.4.1 installed; `xcodebuild` works after `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. First `xcodebuild test` cold run was still slow (~5 min, 38 sec) because of swap-thrashing — 16 GB filled up with Chrome (~1.6 GB across helpers) + Claude (~1.1 GB across helpers) + Xcode + 4 simulator clones, pushing 4.77 GB to swap. Mitigation for future sessions: quit Chrome / OneDrive / Messages before `Cmd+U`. Subsequent test runs reuse simulator clones and are much faster. 32 GB is the right long-term target.
- **`docs/w4-block-detail-spec.md` locked** (commit `ef8af35`). All design decisions baked in from chat: `.sheet(item:)` with `.medium` / `.large` detents, invisible 20pt-wide polyline tap overlay with `MapAnnotation` midpoint fallback, severity color band + block header + safety label + rule list + disabled "Park here →" stub button, selected-block highlight via `@State` + ternary on `lineWidth` (no per-segment re-render), accessibility labels per palette doc §5.1 (absorbs W3 QA #8 carry-over), R1 stress test required on real device before merge.
- **W3 follow-up fixes debunked.** Initial plan was a precursor PR fixing W3 QA findings #1 (HP-11 wrong assertion), #2 (missing bare-FREE test), and #5 (double `currentState` call per render frame). On verification against `main`: all three are **already merged in W3 PR #15 (`8d25280`)** — HP-11 has `> 19.0 && < 20.0`, HP-12 (bare FREE block test) exists at line 597, ContentView caches `engine.currentState(...)` in a `let state` and derives both color and `lineWidth` from it. The W3 QA report was reviewing branch snapshot `7e5be22` before the engineer applied the fixes; post-fix state landed in the squash-merge. Test count is **43 passed, 0 failed** on Xcode 26.4.1 / iPhone 17 Pro simulator. `docs/w3-followup-fixes-spec.md` was written and then deleted (commits `ef8af35` → `f9c901c`) once this was discovered. Net: skip directly to W4.
- **HANDOFF Phase 5 table** updated: W4 row now says "📋 spec ready, awaiting `@ios-engineer` dispatch" with full pointer to `docs/w4-block-detail-spec.md`. Carry-over deferrals section corrected to note W3 QA #1, #2, #5 are already-merged (not open) and #8 is absorbed into W4.
- **Session ending posture.** The Claude Code session running this work was started from `~/Documents/WePark` (old path), so the project's six-agent team at `.claude/agents/` was not loaded as invokable subagent types. Next session should be started from `~/repos/parkmap` so `@ios-engineer`, `@qa-verifier`, etc. auto-load. Then dispatch `@ios-engineer` with `docs/w4-block-detail-spec.md` as the brief.

### 2026-05-10 — Phase 5 iOS Swift native build, W1a–W3 merged

Massive week. Built the iOS app from zero to "tappable map with live dynamic colors" in five PRs across two days:

- **PR #12 — W1a (Xcode scaffold).** Xcode 16 project at `ios/WePark/WePark.xcodeproj`. Bundle ID `com.wepark.app`, iOS 17 deployment, iPhone-only, portrait-only. Privacy strings for location + notifications. Module structure under `WePark/{Models,Views,Services,Resources}/`. All 1,028 tiles bundled + `asp-2026.json` (42 ASP suspension dates). MapKit stub showing Manhattan. **QA caught**: Xcode 16's `PBXFileSystemSynchronizedRootGroup` flattens `Resources/` subdirs into the app bundle root → `Bundle.main.url(forResource:withExtension:)` is the only safe loading path.
- **PR #14 — W1.5 (palette + viz spec).** `docs/design/ios-mvp-palette.md`. **Option B locked**: color encodes CURRENT STATE, not static category. 4-color severity spectrum red→orange→amber-yellow→green + gray for unknown. Same ASP block changes color through the week as its current state changes. Amber-shifted yellow `Color(red: 0.92, green: 0.76, blue: 0.0)` for metered to remain readable against Apple Maps' tan basemap.
- **PR #13 — W2 (tile loader + polylines).** `Models/{Segment,ParkingRule,Category}.swift`, `Services/TileLoader.swift`, `ContentView.swift` polyline rendering. Coordinate order is `[lat, lng]` (visually verified — polylines align with real streets). **QA caught**: stale-region race in `TileLoader.loadTiles(forRegion:)` Task closure — rapid pans could let a late-finishing Task overwrite the segments with the older viewport's tiles. Fixed by reading `self.currentRegion` at Task execution time instead of the captured `region` parameter.
- **PR #15 — W3 (rules engine + dynamic state color).** `Services/ParkingRulesEngine.swift` (port of `actionableSafetyLabel`, `computeNextRestrictionHours`, `meteredStatusLabel`, etc. from `index.html`), `Services/ASPSuspensionService.swift`, `Services/StreetNameNormalizer.swift`, `Services/Date+ET.swift`, `Services/ParkingColors.swift`, plus `Models/{SafetyLabel,NextRestriction,CurrentState,ASPSuspension}.swift`. 43 parity tests pass (all 5 R2 boundary cases — Sat→Sun rollover, end-of-month, start-of-year, suspended-day adjacency, midnight ET exactly). All time math via `Calendar.easternTime` — zero `Calendar.current` usage. ContentView refactored to use `engine.currentStateColor(for: segment, at: now)`; 60s timer + onAppear + camera-settle recompute cadence. **QA caught**: HP-11 test assertion bound was wrong (assumed ASP_TUE_FRI only hits Fridays, ignored Tuesdays). **Side effect: W2 had a subtle ASP_DAILY day-mask bug** (returned true for all 7 days including Sunday) — fixed in this PR per JS behavior (Mon-Sat only).
- **QA reports**: `docs/qa/{w1a,w2,w3}-pass-1-*.md` each landed alongside their feature.

Repo now has:
- 3 PRs of agent-team / spec / business model setup (PRs #9, #10, #11)
- 4 PRs of iOS code (PRs #12, #13, #14, #15)
- The independent-QA pattern (engineering agent ≠ QA agent) validated three times in a row; each pass caught at least one finding the implementer missed.
- Memory note: clean builds slow on 8 GB Macs (10–15 min). Hardware upgrade or folder-reference refactor on tiles recommended.

Visual confirmation done in simulator at end of session: Manhattan map renders with all polyline colors correct for the current time (Mon ASP blocks orange because Mon morning is <24h away, Tue/Fri ASP blocks green because next cycle is >24h, NO_PARKING blocks red, midtown metered blocks amber-yellow).

### 2026-05-08 — Agent team setup + iOS launch decision + business model

- PR #9: Six-agent team under `.claude/agents/` (`tech-lead`, `ios-engineer`, `pwa-maintainer`, `backend-data`, `designer`, `qa-verifier`) + operating manual at `.claude/TEAM.md`. Independent-QA pattern codified as a structural invariant. Engineering agents on disjoint files can run in parallel.
- PR #10: First iOS MVP spec (`docs/ios-mvp-spec.md`). Decision-density format: §3 lists every binding choice with rationale.
- PR #11: 7 spec decisions locked (MapKit not Mapbox; `com.wepark.app`; bundle tiles; contextual permissions; iOS 17 min; privacy strings as-drafted; iOS-native semantic palette via Designer). `docs/business-model.md` captures Free+Pro subscription strategy ($4.99/mo, $29.99/yr, 7-day trial, MVP ships free, paywall in v1.1). HANDOFF + PROJECT tile counts corrected (976 → 1,028; 6.39 MB → 27 MB on disk).

### 2026-05-01 — Drive Mode v3 search upgrade (Mapbox Search Box API)
- Replaced legacy Mapbox Geocoding v5 (`/geocoding/v5/mapbox.places/`) with **Search Box API** (`/search/searchbox/v1/suggest` + `/retrieve`). Search Box has dramatically better POI/business/brand coverage — "Whole Foods Bowery", "Joe's Pizza", "Trader Joe's" now resolve to actual restaurant/store locations the way Apple Maps does.
- Two-step flow: `/suggest` for autocomplete (returns `mapbox_id`), `/retrieve` to fetch coordinates when user picks. Single `session_token` across both = single billed search (Mapbox session pricing).
- Result list now shows category icons: 🍽️ restaurants, 🛒 grocery, 🍺 bars, 🛍️ shopping, 🏋️ gyms, 🏥 medical, 🌳 parks, 🎓 education, 🏨 hotels, ⛽ gas, 📍 addresses.
- Result name + address line ("Whole Foods Market" · "270 Greenwich St").
- Free-tier limits: 50k suggest + 50k retrieve per month — way more than we'd hit.
- SW cache bumped to `wepark-v30`.

### 2026-05-01 — Drive Mode v3 full (3b+3c+3d+3e: turn-by-turn + heading-up + re-route + arrival + parking-aware)
After v3 Phase 3a Kevin reported the missing piece was real Apple-Maps-class navigation. Shipped the rest of v3 in one chunk.

- **Heading-up map rotation.** `body.driving-mode #map { transform: rotate(var(--dm-heading-rot)) scale(1.45) }`. Each GPS tick updates the CSS variable to `-heading`. Scale 1.45 keeps corners covered as we rotate. Smoothed via 600ms cubic-bezier transition. Skipped if heading change < 5° (less churn). The car icon's existing `heading - 90` rotation combined with the map rotation results in the car always pointing UP on screen, exactly like Waze/Google/Apple Maps.
- **Top turn ribbon** (`#dmTurnRibbon`): Apple-Maps-style green band with maneuver icon (↰ ↱ ↩ ⬆️ 🏁 ⟳), distance ("200 ft" / "0.3 mi" / "Now"), and instruction text. Switches to **blue "approaching"** at <200m and **purple "you've arrived"** when on the last step within 80m.
- **Step tracking**: walks `route.legs[].steps[]` (flattened via `flattenSteps()`); advances `drivingCurrentStepIndex` when the user is past the current step's maneuver location and closer to the next one.
- **Turn voice**: tiered announcements (~400m / ~150m / now). Doesn't cancel parking-status voice — speaks alongside it. Replaces "St"/"Ave"/"Blvd"/"Rd" with full words for clarity.
- **Re-routing on deviation** (Phase 3d): every GPS update measures min distance to the route polyline. If >50m for >5 seconds, says "Recalculating" and calls Mapbox Directions again from the user's current position. New route replaces the old one, step tracking resets.
- **Arrival prompt** (Phase 3e): when user is within 40m of the destination AND speed < 1.5 m/s, plays "You've arrived. Park here?" via voice. Turn ribbon switches to purple "You've arrived" tier.
- **Parking-aware route selection** (Phase 3c): Mapbox Directions called with `alternatives=true` (up to 3 routes). Each route scored by counting unique block faces with free/metered parking within 30m of the route polyline (sampled every Nth point). Score = `3 × free_blocks + 1 × metered_blocks − duration/600`. Best route chosen.
- All cleanup paths (drive-mode exit, destination clear, re-route) reset all state including step index, voice tiers, off-route timer, arrival flag, and map rotation CSS variable.
- SW cache bumped to `wepark-v30`.

### 2026-05-01 — Drive Mode v3 Phase 3a (destination input + Mapbox routing)
- New entry flow: tap **🚗 Driving Mode** → if no Mapbox token, show token-entry modal first → then destination modal → then Drive Mode UI activates.
- **Token modal** (`#dmTokenModal`): pastes a `pk.*` Mapbox public token, validates format, saves to `localStorage.wepark_mapbox_token`. Skip option enters Drive Mode without routing (v2.1 behavior).
- **Destination modal** (`#dmDestModal`): input field + live Mapbox Geocoding autocomplete (`/geocoding/v5/mapbox.places/`, debounced 280ms, Manhattan-biased via `proximity` + `bbox`, top 5 results, types include addresses, POIs, neighborhoods). Recent destinations rendered as chips (last 6 stored in `localStorage.wepark_drive_recent_destinations`). Skip option also drops to v2.1 behavior.
- **Mapbox Directions API** (`/directions/v5/mapbox/driving/`) called once on entry with destination set. Returns route GeoJSON + steps (steps are stashed for Phase 3b voice but not used yet).
- **Route render**: thick blue line (weight 7) with white underglow (weight 11) drawn on top of the map. 📍 destination pin at the end. Pulsing green marker + thick dashed green polyline on the **best free-parking block within 300m of the destination** — picked via `findBestParkingBlockNear()` which uses the existing `actionableSafetyLabel()` scoring (free=high score, metered=lower, restricted=excluded).
- **Top destination strip** (`#dmDestStrip`): floats below the top bar with `🎯 [destination name] [✕]`. Clear button removes the route + destination without exiting Drive Mode.
- Cleanup: all v3 layers (route, dest pin, target block highlight, target marker) removed on Drive Mode exit OR on destination clear.
- **Token NOT in source code** — GitHub's push protection blocks `pk.*` Mapbox tokens. Kevin's existing token (created 2026-05-01, URL-restricted to `kevhox1.github.io` + `localhost:8765`) stored only in `localStorage.wepark_mapbox_token`. The token modal handles first-use entry; Kevin can also preset via DevTools `localStorage.setItem('wepark_mapbox_token', '<pk.string>')`.
- Out of v3 Phase 3a: turn-by-turn voice (Phase 3b), parking-aware alt-route selection (3c), re-routing on deviation (3d), arrival prompt (3e). All in `docs/drive-mode-routing.md`.
- SW cache bumped to `wepark-v30`.

### 2026-05-01 — Drive Mode v2.1 (visual polish)
- Replaced the blue dot user marker with an Apple-Maps-style **🚗 car emoji** in a white circle with a blue ring + pulse outline. Rotates with GPS heading (offset −90° because the car emoji's natural orientation faces east, not north).
- Bumped Drive Mode zoom from 17 → **18** so the current block dominates the view, like Apple Maps in turn-by-turn mode.
- New **side-of-street highlight overlay**: when the current block is detected, both LEFT and RIGHT side polylines are drawn extra-thick (weight 9) on top of the regular map, with a white underglow (weight 14) for legibility, and colored by parking severity (free=green, metered=yellow/orange, restricted=red, unknown=grey). Driver can immediately see which side of the road they should be looking at, with the colors matching the bottom-card text.
- Highlights cleared + redrawn only when the block changes (no per-tick churn).
- Cleanup on Drive Mode exit: highlights removed and pre-entry map view restored.
- New spec file `docs/drive-mode-routing.md` for the v3 build (destination input + Mapbox routing + parking-aware path selection). Build deferred — needs Kevin to create a Mapbox account first.
- SW cache bumped to `wepark-v23`.

### 2026-04-26 — Drive Mode v2 (map-centric, Waze/Google Maps-style)
- v1 missed the mark per first user — black-screen text-card UI lost spatial context. v2 rebuilds Drive Mode as a transparent overlay *on top* of the existing Leaflet map, so the map IS the interface.
- `body.driving-mode` class hides `#controlPanel`, `#startScreen`, `#pwaInstallHint`, `#weparkVersionChip`, and Leaflet zoom controls so the map fills the whole screen.
- `#drivingMode` is now `pointer-events: none` so map gestures pass through; only the floating top bar (✕ Exit, 🔊/🔇 mute) and the floating bottom card opt back into pointer events.
- On entry: stash current map view (center+zoom), set zoom 17, attach a pulsing custom user marker (`L.divIcon` blue dot + heading-rotated arrow + animated pulse ring). On exit: remove marker, restore the prior view.
- `onDrivingGeoUpdate` now `setView`s the map (not just panTo) so zoom stays locked at 17 and the user pin remains centered. Marker icon is rebuilt every tick with the current heading rotation.
- Bottom card replaces the v1 card layout — compact glanceable strip with street name + LEFT/RIGHT actionable rows + speed/accuracy meta. Border-left color band uses the worse-severity of L vs R.
- Voice unchanged from v1 (street-change announcements, rate-limited, mutable).
- Out of v2 scope: map auto-rotation by heading (Leaflet doesn't natively rotate; would need a plugin or CSS transform — deferred to v3 if user wants it). Streets are colored by parking category via the existing rules layer; no extra current-street highlight in v2.
- SW cache bumped to `wepark-v22`.

### 2026-04-26 — Driving Mode v1 (PoC, abandoned same day)
- After real user feedback ("incredibly difficult to use live in the car"), introduced a separate full-screen **Driving Mode** view optimized for a phone propped on a dashboard mount. Spec: `docs/driving-mode.md`.
- Entry: 🚗 Driving Mode button at the top of the panel body. Tap → request GPS + screen wake-lock → full-screen overlay takes over.
- UI strips everything except the actionable info: giant street name, color band (green/yellow/red), LEFT side label, RIGHT side label. No map, no tabs, no chat — read-only, glanceable.
- LEFT/RIGHT computed from GPS heading (`coords.heading`) vs each side polyline's compass bearing (W/E/N/S). Falls back to N/W=Left, S/E=Right if heading unavailable (e.g., user stopped).
- New `actionableSafetyLabel(seg)` returns `{ text, severity }`. Reuses `computeNextRestrictionHours` and `meteredStatusLabel`. Examples: "Free until Thu 9:30am", "Metered until 7pm", "Free until 9am" (overnight metered), "No parking", "No standing".
- New `getCurrentDrivingContext(lat, lng, heading)` resolves the user's current block (street + from + to) via `findClosestSegment`, then both side segments via `findSegmentByBlock`, then assigns LEFT/RIGHT.
- Voice via `window.speechSynthesis`, fired only on block change (not every GPS tick), rate-limited to once per 12s, mutable via 🔊/🔇 button (preference persisted in localStorage). Format: "Bowery. Left side, free until Thursday 9:30am. Right side, metered until 7pm."
- Wake lock acquired on entry (`navigator.wakeLock`); re-acquired on tab visibility change; released on exit.
- Map auto-pans to user's GPS location while in driving mode so tiles for the current area keep loading.
- Out of v1 scope: turn-by-turn navigation, pre-set "intent" mode, voice commands, "Park here now" auto-detect.
- SW cache bumped to `wepark-v20`.

### 2026-04-22 — Park-pin & route polish
- **Park pin no longer snaps.** The "Park My Car Here" flow used to snap the marker onto the side polyline of the auto-detected segment after the user confirmed N/S/E/W. At corners and intersections this could move the marker 30-50m away from where the user actually tapped (and onto the wrong street). The marker now stays at the exact lat/lng the user picked. The detected segment is still used for parking-rules lookup but no longer for visual placement.
- **"Wrong street?" alternatives in the park modal.** New `findCandidateSegments(lat, lng, radius=35, max=4)` returns the closest unique blocks within 35m of the pin. The park modal renders any non-default candidate as a button ("Wrong street? Pick another nearby block: 1ST AVENUE (33m)"). Clicking switches `_parkDetectedSeg` and re-renders side options. Fixes the corner-detection ambiguity Kevin flagged.
- **Route excludes the block you're already parked on.** `scoreEdgeCoverage(edgeId, skipBlockKey)` now accepts a skip key built from `parkedBlock.street|from|to`. The route generator passes it in so the algorithm doesn't say "scan this block at 0m" for the spot you're already in.
- **Metered status label fix.** `computeNextRestrictionHours` intentionally `continue`s on METERED rules ("not a move-your-car restriction"), so pure-metered blocks returned the default `168h`. The route sidebar now uses a new helper `meteredStatusLabel(seg)` that shows: `Metered (paid until 7pm)` when active, `Metered (free until 9am)` when not, `Metered (free for Nd)` if next activation is far. No more 168h on any metered block.
- **`attachBlockFacesToEdges` cache fix.** First-route runtime was 2.8s due to rebuilding the canonical-name index on every call. Now built once per session into `streetGraph._edgesByCanonStreet`, then reused. Subsequent route requests run in ~235ms even when segmentLayers grows.
- SW cache bumped to `wepark-v11`.

### 2026-04-22 — Coverage-sweep route planner (replaces TSP)
- The "Find Parking Near Me" route now uses a **greedy coverage sweep** instead of held-karp TSP on top-10 candidates. Reasoning: the TSP-on-waypoints model produced routes that backtracked oddly and over-weighted metered blocks (`168h × 1` was beating `48h × 3` ASP scores). Real parking-search behavior is a coverage sweep — drive a logical loop, scan whatever's good along the way.
- New flow:
  1. `attachBlockFacesToEdges()` matches loaded block-face segments to the directed graph edges they cover (canonical street name + midpoint distance ≤ 60m). Cached on `segmentLayers.length`; the canonical-name index `_edgesByCanonStreet` is built once and reused.
  2. `scoreEdgeCoverage(edgeId)` returns a coverage value: ASP-done blocks get +10 each, ASP-soon scaled +1 to +8, **metered blocks get +0.5** (intentionally bottom-of-the-rank). Active restrictions and No Standing/Truck/Special blocks score 0.
  3. Greedy walk: at each intersection, pick the highest-scoring unvisited outgoing edge; ban immediate U-turns; heavily penalize revisits (-100 × visit count); past 60% of distance budget, bias toward edges that close the gap to the start point. Stops at 2.5 km total OR when within 90m of start after ≥600m driven.
- Rendered as a **single drawn polyline** (green path with white underglow) following actual streets, plus colored highlights on every scanned block face: `#15803d` for ASP done, `#65a30d` for ASP soon, `#0ea5e9` for metered. Start pin is a small green dot. No more numbered destination markers.
- Sidebar info shows: total distance + drive time, summary count of ASP-done / ASP-soon / metered blocks, collapsed turn-by-turn (consecutive same-street steps merged), and a collapsible "Scanned blocks" list. Google Maps / Apple Maps deep-link uses every Nth intersection along the path so the external map traces the same route.
- **Smoke test from 217 Bowery**: 14 blocks scanned (3 ASP done ✅, 11 ASP soon, 0 metered), 1.0 km / ~4 min drive, loop closes 85m from start. Path: Stanton → Chrystie → Houston → Forsyth → Chrystie → Rivington → Bowery → Spring → Bowery. Initial route ~2.8s due to 17K-edge canonical-name index build; subsequent calls are fast since `_edgesByCanonStreet` is cached.
- SW cache bumped to `wepark-v10`.
- **Known gaps** to revisit: (a) the algorithm should drop "current parking block" from candidates so it doesn't say "scan this block you're already on" at 0m; (b) `computeNextRestrictionHours` returning 168h for some metered blocks looks suspicious — needs a check on weekend/holiday boundary cases; (c) cache could be invalidated incrementally as tiles load (right now we wait until full route request to attach).

### 2026-04-21 — One-way aware parking route with mini-TSP
- `osm_oneway.json` added (1.25 MB): Manhattan street geometry + per-segment direction (`FT`/`TF`/`TW`) pulled from NYC DOT Centerline (CSCL) dataset `inkn-q76z`. 12,203 rows → 1,088 unique streets, 12,245 way-segments after excluding non-vehicular (NV). Build script at `scripts/build-oneway-data.js` — re-run when NYC updates the centerline (quarterly).
- Street-name canonicalizer added. `canonicalStreetName` converts both tile-data names (`1ST AVENUE`, `CHRYSTIE STREET`) and centerline names (`1 AVE`, `CHRYSTIE ST`) to a single canonical form (`1 AVE`, `CHRYSTIE ST`). Known alias: `AVE OF THE AMERICAS` → `6 AVE`. Join rate to tile data: ~97.5%.
- `loadStreetGraph()` runs in parallel with `loadTileIndex` and `loadASPSuspensions` during init. Builds a directed graph: nodes = intersections snapped to 4-decimal grid (~11m), edges = directed street segments based on `oneway` flag. Current numbers: 17,326 intersections, 26,474 directed edges.
- `driveDistance(from, to)` computes meters of drive distance respecting one-ways. Backed by A* search (binary-heap priority queue, haversine heuristic). Capped at 4km / 3000 nodes per query to prevent runaway. Falls back to crow-flies if graph isn't loaded, or crow × 1.5 if the query is within-budget unreachable. Per-query runtime ~1-5ms.
- `generateParkingRoute()` replaces polar-angle sort with held-karp mini-TSP on the top 10 candidates (open path starting from the user, ending anywhere). 11×11 drive-distance matrix built via `driveDistance`. TSP DP is O(2^N · N²) = ~10k ops, runs in <5ms. Full route generation (including rendering) measured at ~170ms.
- Pass-count bonus added: pre-TSP, any two candidates on the same street within 250m boost each other's routeScore by 1.25×. Encourages the router to pick "two-for-one" scan opportunities.
- Verified end-to-end: going north on 1 AVE (one-way uptown) = 2054m; going south (must detour via 2 AVE) = 2550m. One-way honored. Fallback verified by stubbing `streetGraph = null`: app falls back to crow-flies without error.
- SW cache bumped to `wepark-v9`; `osm_oneway.json` added to static-asset precache.

### 2026-04-17 — Tracker production hardening (pre-Supabase)
- Mock provider output now routes through `normalizeTrackerReport` / `normalizeTrackerDetail` for every read and write path (`getActiveReportsForBounds`, `getBlockFaceDetail`, `getNearbyFeed`, `createReport`, `confirmReport`, `retractReport`). Mock and Supabase now return identical shapes — `trackerDetailCache` and downstream UI can't diverge between the two.
- Supabase provider `init()` now runs a connectivity probe (one lightweight `tracker_get_active_reports_in_bbox` RPC with a 4-second timeout). Bogus creds, unreachable URLs, missing schema, or bad anon keys now throw during init instead of silently passing and failing on every runtime call. `initTracker()` catches the throw and falls back to the mock provider when `allowMockFallback` is true. Verified end-to-end in local smoke: bogus `https://*.supabase.co` URL + bogus anon key → probe throws `supabase_unreachable` in ~130ms → mock takes over cleanly.
- RPC name / signature cross-check between `index.html` Supabase provider and `SUPABASE_MVP_SCHEMA.md` — all 7 RPCs match (names and parameter names). No schema doc changes required.
- SUPABASE_MVP_SCHEMA.md now flags the JS mock as the reference implementation for merge/conflict/dedupe semantics; SQL RPCs must match its behavior.
- SW cache bumped to `wepark-v7`.

### 2026-04-17 — Post-merge QA audit of threat tracker
- `TRACKER_QA_PASS_2.md` added. Fresh QA pass against `main` at `1f8b005` (post PR #5 + PR #6). All six previously-open issues from `TRACKER_QA_VERIFY.md` verified as structurally resolved in code. 10 new low-severity observations logged (provider shape divergence between mock and Supabase; legacy config shim; mock-only `seedReports`; etc.). Verdict: qualified yes for real Supabase wire-up, pending two live smoke checks (mock-vs-Supabase detail-shape normalization + Supabase-bad-creds → mock-fallback).

### 2026-04-17 — Supabase-ready tracker provider + QA fixes
- PR #5 (`a45098b`): real Supabase tracker provider with dynamic `supabase-js` import, auth gate state API, RPC wrappers for `tracker_get_active_reports_in_bbox` / `tracker_get_block_face_detail` / `tracker_get_nearby_feed` / `tracker_create_report` / `tracker_mark_block_cleaned` / `tracker_confirm_report` / `tracker_retract_report`, optional realtime channel. `tracker-config.js` introduced to select provider and hold creds. Graceful fallback to local mock if init fails. SW now bypasses Supabase hosts (never cache `*.supabase.co` / `/rest/v1/` / `/auth/v1/` / `/realtime/v1/` / `/functions/v1/` / `/storage/v1/`). SW cache bumped to `wepark-v6`. Tile cache state changed from boolean to `'loading' | 'loaded'` with cleanup on fetch failure so failed tiles can retry within a session.
- PR #6 (`aa7c5bd`): tracker QA follow-ups. Park My Car CTA now wired to `parkCarHere()` (one-tap pin flow) instead of the modal. Block-face nearest-segment detection now uses projected point-to-polyline distance (`getClosestPointOnSegmentGeometry`) instead of nearest vertex only. `block_cleaned` aging respects `asp_window_end_at` instead of generic 10-minute stale rule. ASP next-restriction timing walks 14 future days, skips `isASPSuspended` dates, and honors `rule.days`. Smart Move button and panel now share `computeSmartMove()` output. Narrow-phone bottom-sheet coordination via `isCompactBottomSheetLayout()` / `syncResponsivePanels()` so only one sheet is visible at a time on small screens. `showBlockInfo` wraps tracker detail + auth fetch in try/catch so backend failures don't crash the block popup.

### 2026-04-07 — Initial threat tracker slice
- PR #4 (`f8ba00b`): first tracker slice. Mock provider with localStorage persistence, auth gate, tracker overlay on the map, feed panel with nearby reports, report composer for sweeper / ticket-agent / block-cleaned events, confirm / retract actions. Provider-abstracted so the Supabase one can drop in later. SW cache bumped to `wepark-v5` (commit `8720a3a`).

### 2026-04-02 — Street-based Park My Car + cross-street normalization + Top Blocks
- PR #3 (`d6788b0`): Park My Car reworked to take a street name with smart side confirmation.
- PR #2 (`211a73c`): normalized spelled-out cross streets (`FIRST AVENUE` ↔ `1ST AVENUE`, etc.) so block-face matching stops dropping entire sides of the street.
- PR #1 (`5746e1d`): Top Blocks ranked panel for Smart Score mode.
- SW cache bumped to `wepark-v4` (commit `179904c`) and `wepark-v3` earlier.

### Pre-April 2026 — Phase 1 & Phase 2 foundations
- Phase 1 (2026-03-27): PWA manifest, service worker, GitHub Pages deploy, mobile UI polish, tile-based lazy load.
- Phase 2 (through 2026-04-02): Smart Move, Smart Score, My Car pin with localStorage, route optimizer.
- Data pipeline fixes along the way: dedup bug dropping ~50% of signs (`dc16002`), sub-segmentation bug dropping ~75% (`f65d08f`), merging ASP-only streets into the main dataset (`c33c6f3`), Jekyll bypass via `.nojekyll` (`ac76cde`).

## Open questions / known gaps

- **Supabase not provisioned.** `tracker-config.js` still has empty `supabaseUrl` / `supabaseAnonKey`. Before flipping `provider` to `'supabase'`, Kevin needs to: create the Supabase project, apply `SUPABASE_MVP_SCHEMA.md`, enable anonymous auth, and populate the config. RPC names are already verified to match between provider and schema.
- **No automated tests.** If behavior-critical work lands, consider what lightweight in-browser smoke coverage would be worth adding (e.g., a manual QA checklist per PR, or a small hand-written test harness loaded behind a URL flag).
- **PROJECT.md freshness cadence is manual.** It gets stale unless updated as part of the PR that changes things. Consider making it a checklist item in PR descriptions.
- **SW cache discipline.** Tile freshness depends on bumping `CACHE_VERSION` when tile data changes. No automatic invalidation on content hash. TRACKER_QA_VERIFY flagged this as an unresolved concern.
- **Tracker QA gaps that were closed in PR #6 but not independently re-verified post-merge.** The QA agent that wrote `TRACKER_QA_VERIFY.md` reviewed an older snapshot. A fresh QA pass against `main` post-#6 would be worth doing before the real Supabase wire-up.

## Quick start for a new session

Tell a new Claude:

> Read `HANDOFF.md`, `PROJECT.md`, and `TRACKER_MVP_SPEC.md` at the repo root. Then ask me what we're working on. Don't push to `main`; use a topic branch and a squash-merged PR. Bump `CACHE_VERSION` in `sw.js` on any asset change.
