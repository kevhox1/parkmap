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
| **W7** — ASP banner + settings + per-pin toggle + toast primitive | ✅ merged (PR #24) | `Views/ASPBanner.swift` (new — 3-state banner via `.safeAreaInset(edge: .top)` reading `ASPSuspensionService.suspensionState(at: .nowET)`); `Views/SettingsView.swift` (new — gear-icon sheet with global mute toggle + version/build footer, no Terms link); `Services/ToastService.swift` + `Views/ToastHostView.swift` (new — reusable singleton-with-`private init()` + `#if DEBUG resetForTesting()`; slide-down/fade with safe-area-aware top inset via scoped `GeometryReader`); `ParkedCar.notifyOnRestriction: Bool` (defaults `true`, `decodeIfPresent` for pre-W7 pins) with toggle in `ParkConfirmView` + editable in `ParkedCarDetailView`; `NotificationScheduler.schedule(...)` guards per-pin opt-out AFTER global mute (correct order); `RuleRow` in `BlockDetailView` is tap-to-expandable (`.lineLimit(isExpanded ? nil : 1)` + `.easeInOut(0.18)`), fix propagates to `ParkedCarDetailView` automatically. **Tests: 72/0** (+12 W7 tests). Spec: `docs/w7-asp-banner-settings-spec.md`. QA: pass-1 SHIP WITH CAVEATS (3 actionable findings) at `docs/qa/w7-pass-1-2026-05-15.md`, pass-2 SHIP WITH CAVEATS-effectively-clean (only nit-level new observations) at `docs/qa/w7-pass-2-2026-05-15.md`. **Engineer agent flaked twice on background sub-agent permissions for pass-2 fixes**; main session made the 3 mechanical fixes directly (`private init`, safe-area inset, imports cleanup) to preserve momentum — independence invariant preserved because pass-2 QA was still a fresh agent reading the diff cold. Worktree-local `.claude/settings.json` was the binding permission file for sub-agents — see `memory/feedback_worktree_settings.md`. |
| **W7.5** — "Park Until X" filter | ✅ merged (PR #27) | `Services/ParkingRulesEngine.swift` (new `isFree(segment:from:until:)` interval-walker + `timeRangeOverlaps` helper, ~145 LOC); `Views/ParkUntilSheet.swift` (new — 6 preset pills "30 min / 1 hr / 2 hr / 4 hr / Tonight / Tomorrow 9am" + DatePicker(.compact) secondary, 7-day cap, relative-date-aware time formatting); `Views/ContentView.swift` (`ActiveSheet.parkUntil` case (no payload), clock.fill toolbar button in recenter button stack, binary recolor in `rebuildOverlays` via `engine.isFree`, bottom pill via `.safeAreaInset(edge: .bottom)`, stale-target guard in `.onChange(of: scenePhase)`, pin-clear filter cleanup). **Tests: 116/0** (+20 new engine tests). Spec: `docs/w7.5-park-until-x-spec.md` (§12 "As-Shipped Amendments" documents the three smoke-driven pivots from pin-drop-trigger to standalone-toolbar-trigger, 24h cap to 7-day cap, bare time format to relative-date format). QA: `docs/qa/w7.5-pass-1-2026-05-16.md` (SHIP CLEAN — main session executed because qa-verifier sub-agent flaked on Bash for the 3rd consecutive time). **Kevin's smoke caught three real UX issues that QA missed by static analysis** (commit-before-discover, 24h cap too low, ambiguous time format without date) — validates the smoke gate above the QA gate. |
| **W8.5a** — Mapbox HTTP Directions + RouteService foundation | ✅ merged (PR #28) | `Services/RouteService.swift` (new — async/await wrapper around `https://api.mapbox.com/directions/v5/mapbox/driving/...`; injectable `URLSession` + token provider for tests; `MapboxRouteError` for `.missingToken`/`.network`/`.http(status:)`/`.decoding`/`.noRoutes`); `Models/DriveRoute.swift` (new — `DriveRoute` + `DriveRouteStep` with `[CLLocationCoordinate2D]` geometry and maneuver type/modifier/instruction/location; manual `Equatable` since `CLLocationCoordinate2D` isn't); `WeParkTests/RouteServiceTests.swift` (new — 10 `URLProtocol`-mocked cases: single route, alternatives, network error, 4xx, 5xx, empty routes, missing token, whitespace token, URL query params, GeoJSON `[lng,lat]` → `(lat,lng)` ordering); `ios/WePark/Info.plist` (new stub — bridges `MAPBOX_ACCESS_TOKEN = $(MAPBOX_ACCESS_TOKEN)` from `Config.xcconfig` into the merged auto-generated Info.plist); `ios/WePark/Config.xcconfig.example` (committed setup doc; real `Config.xcconfig` is gitignored); `project.pbxproj` (Config.xcconfig set as `baseConfigurationReference` for Debug + Release; `INFOPLIST_FILE = Info.plist`). **Tests: 126/0** (+10 RouteService tests). Spec: `docs/drive-mode-scope-spec.md §4 + §7 W8.5a row` (re-scoped from the spec's W8.5b "destination + routing" stream to be foundation-only — no UI surface; destination input ships in W8.5b). QA: `docs/qa/w8.5a-pass-1-2026-05-20.md` (SHIP CLEAN after smoke-test fix — Pass-1 read-only QA at `5764182` signed off, but **Kevin's smoke test of the built `.app` Info.plist caught a runtime bug** the unit tests couldn't catch by design: `INFOPLIST_KEY_<custom>` build setting is silently dropped for non-Apple-defined keys, so `Bundle.main` would have returned `nil` for `MAPBOX_ACCESS_TOKEN` in production. Fix `53bb7c6` added the `Info.plist` stub + `INFOPLIST_FILE` setting; PlistBuddy now confirms the token is present in both Debug and Release built bundles and the auto-generated Apple keys are preserved). **Process lesson:** PRs that wire build-setting → runtime values via Info.plist need a smoke check on the built bundle (`PlistBuddy -c "Print :KEY" <built>.app/Info.plist`), not just mocked unit tests — added to the W8.5b+ QA checklist via this row. Live Mapbox HTTP smoke against the real token: HTTP 200, valid 5.3km / 23min NYC route, 283 geometry points. |
| **W8.5c-polish** — Apple-Maps-isms + bottom card chip doc + cosmetic fixes | ⏪ **MERGED THEN REVERTED 2026-05-26** (PR #31 merged as `2df5603`, reverted by `8036d25` same day) — see Changelog 2026-05-26 entry for the revert rationale. Kevin's smoke surfaced a live SwiftUI overlay regression that QA missed: the entire toolbar layer (gear / find-me / find-car / clock / Drive button) + ASP banner + Park Until pill all stopped rendering after W8.5c-polish merged. Tests still passed (210/0) because they exercised units in isolation, not the live mount chain. Combined with reports of "longer load + noticeable lag," the most likely culprits are the auto-zoom + tilt machinery firing during view construction before SwiftUI finished mounting the parent hierarchy, OR the `headlessWindow` test-infrastructure guard inside `syncDriveCamera` actually firing in production despite QA verifying the "never reached" claim. Root cause not yet diagnosed — reverted first to restore the live app, diagnosis deferred. **Re-attempt path**: smoke-test the live UI in the sim BEFORE squash-merging is now a hard gate (added to the ios-engineer + qa-verifier briefs going forward, see Changelog process notes). Original spec at `docs/w8.5c-polish-spec.md` is gone from main with the revert; QA report at `docs/qa/w8.5c-polish-pass-1-2026-05-25.md` is preserved as historical record + annotated with the revert note. | `Views/MapViewRepresentable.swift` (auto-zoom to span ~0.005° + 3D camera tilt to 30° on Drive Mode entry, restore prior camera state on exit, `lastDriveModeActive` Coordinator guard breaks R-1 feedback loop alongside the W8.5c `lastAppliedHeading` dead-band, `headlessWindow` test-infrastructure guard for headless `MKMapView()` in unit tests — **accepted tech-debt**, see note); `Views/DriveModeBottomCard.swift` (distance-to-destination indicator top-right of street name row using `CLLocation.distance(from:)` + `MeasurementFormatter` with `Locale.current.usesMetricSystem` for unit selection; doc-comment explaining the `context: DrivingContext?` state machine — chips render when non-nil, "Looking for street..." placeholder when nil); `ContentView.swift` (End Drive pill z-order vs. W7 ASP banner — pill offset to avoid obscuring banner copy); `docs/w8.5c-polish-spec.md` (spec landed in the PR diff per W8.5c precedent — minor process deviation but consistent). **Tests: 196 → 210** (+14 W8.5c-polish tests: DistanceFormattingTests + DriveCameraDeadBandTests + EndDrivePillLayoutTests + DriveCameraTests). Spec: `docs/w8.5c-polish-spec.md` (all 4 OQs resolved as recommended). QA: `docs/qa/w8.5c-polish-pass-1-2026-05-25.md` — Ship with follow-ups, 18/18 ACs pass. **Two accepted deviations documented (NOT findings — Kevin pre-approved)**: (1) pitch **30°** vs spec'd 45° — MapKit clamps pitch to ~35° at the spec'd zoom (span ~0.005°, altitude ~99,999m), so 45° in code renders as ~35° in practice; engineer shipped 30° which is below the clamp threshold and renders faithfully. **Process miss**: engineer should have flagged before shipping rather than substituting silently. (2) **`headlessWindow` test-infrastructure guard inside `syncDriveCamera`** — production code path whose sole purpose is to satisfy unit tests that instantiate bare `MKMapView()` without a `UIWindowScene`. QA verified the "never reached in production" claim: `MapViewRepresentable` has exactly one production instantiation at `ContentView.swift:303`, always in an active `UIWindowScene`. Tech-debt: restructure tests so they don't need the production guard (W8.5d-or-later). **Both deviations triggered a new spec-fidelity norm** added to `.claude/agents/ios-engineer.md` on commit `445e4a3` — engineers must flag spec deviations and test-infrastructure-in-production smells, not silently substitute. **Critical pre-merge save by QA**: branch was cut from `d3385b4` (pre-norm); main was at `445e4a3` (post-norm) when QA ran. A squash-merge as-is would have silently DELETED the spec-fidelity norm — exactly the kind of silent deletion the norm exists to prevent. QA caught this; orchestrator rebased the branch onto main (norm preserved on polish branch: commit `83fe5de`), pushed `--force-with-lease`, tests re-verified 210/0 on the rebased state, then squash-merged as `2df5603`. |
| **W8.5c** — Drive Mode active layer (continuous location + heading-up + voice + commentary engine) | ✅ merged (PR #30) | `Services/LocationService.swift` (`startDriveMode()`/`endDriveMode()` continuous + heading API, exposed `authorizationStatus: CLAuthorizationStatus` for the auth-gate seam); `Services/AudioSessionManager.swift` (`.playback` + `.duckOthers`/`.interruptSpokenAudioAndMixWithOthers`, `.notifyOthersOnDeactivation` on speech-end); `Services/DrivingVoice.swift` (`AVSpeechSynthesizer`, `AVSpeechSynthesisVoice(language: "en-US")`, default rate `AVSpeechUtteranceDefaultSpeechRate`, mute persisted in `UserDefaults`, non-`final` so `MockDrivingVoice` can subclass in tests); `Services/DrivingContextService.swift` (port of `getCurrentDrivingContext` from PWA, block-change detection via 12s min-gap guard, `MockDrivingVoice` for unit tests); `Services/RecentDestinationsStore.swift` (N-1 lift from inline-in-`DriveModeDestinationView.swift` to its own Service); `Views/DriveModeBottomCard.swift` (full-width bottom-pinned card via `.safeAreaInset(edge: .bottom)`, left/right chips + mute toggle); `Views/MapViewRepresentable.swift` (heading-up rotation with `lastAppliedHeading` dead-band breaking the R-1 `regionDidChangeAnimated` feedback loop, recenter pill floating above bottom card when follow-mode paused); `Views/DriveModeDestinationView.swift` (auth-gate carry-over: if `authorizationStatus == .notDetermined`, fires `requestAndFetchLocation()` before route fetch); `Services/RouteService.swift` (M-2 carry-over: `RouteServicing` protocol extraction; `pickBestParkingAwareRoute` converted from `static` to instance method on the protocol since Swift protocols don't take static requirements cleanly with `@MainActor`); `Constants.swift` (new `BackgroundNoteGate` struct + `driveModeBackgroundNoteShownKey = "wepark_dm_bg_note_shown"`); `ContentView.swift` (S-1 carry-over: one-time `.alert("Keep WePark in Front")` on first-ever Drive Mode start, gated by `BackgroundNoteGate` injected `UserDefaults` for testability; Drive Mode bottom card overlay wired). **Tests: 196/0** (+47 W8.5c tests: scoring/EMA/DrivingContext/DrivingVoice/LocationServiceDriveMode/AuthGate/RouteServicing/DriveModeBottomCard/RecentDestinationsStore-N1/HeadingUpRotation + pass-2 BackgroundNoteGate). Spec: `docs/w8.5c-drive-mode-active-spec.md` (389 lines, all 7 OQs resolved as recommendations; spec landed inside the PR diff by engineer choice — minor process deviation from prior convention but reasonable). QA: pass-1 SHIP WITH CAVEATS at `docs/qa/w8.5c-pass-1-2026-05-23.md` (1 Significant S-1 + 3 Minor M-1/M-2/M-3 + 3 Nits), pass-2 SHIP CLEAN at `docs/qa/w8.5c-pass-2-2026-05-23.md` (S-1+M-1+M-3 resolved by 3 surgical commits — `BackgroundNoteGate` + `authorizationStatus` exposure + test comment). **Process lesson**: Engineer correctly avoided opening Xcode this PR (W8.5b's spurious pbxproj reorder did not recur). **Kevin's smoke (Penn Station sim, 2026-05-24)** confirmed: S-1 alert fires once + persists; voice commentary works (announces parking on both sides); block-change detection works. Three smoke-discovered items deferred to **W8.5c-polish** (next stream): heading-up rotation not visibly rotating in the simulator (likely no magnetometer in sim, real-device test required); bottom card showed "Looking for street..." placeholder text in screenshot — needs chip-layout verification vs. spec; End Drive pill overlaps the W7 ASP banner (cosmetic z-order). |
| **W8.5d** — Final approach escalation + arrival prompt → W5 pin-drop hook (first novel destination-mode feature beyond polish) | ✅ merged (PR #35, `3685006`) | First novel destination-mode feature post-trilogy. **Parking-fear payoff moment** — when the user closes within 500m of destination, voice elevates (12s → 4s gap); within 50m the arrival prompt fires; "Park Here" saves the pin at the user's CURRENT location (not the destination) + ends Drive Mode + auto-fires the W7.5 Park Until sheet (Option B per QA pass-1 Finding #1: the arrival-confirm path explicitly opts back into the auto-fire because the user has just committed to parking — distinct from the W7.5 pass-2 standalone-toolbar pivot which was about the commit-before-discover problem). `Services/FinalApproachService.swift` (new — pure static, exhaustive `switch`, no framework deps: `finalApproachState(forDistanceMeters:) -> FinalApproachState` returns `.outside`/`.approaching`/`.arrived` with boundaries 500m + 50m; `voiceGap(for:) -> TimeInterval` returns 12.0/4.0/`.infinity`; `baselineVoiceGapSeconds` constant); `Services/DrivingContextService.swift` (`private let voiceMinGapSeconds = 12` → `private var voiceMinGapSeconds = FinalApproachService.baselineVoiceGapSeconds` + new `setVoiceGap` mutation point — single source of truth, no double-gating); `Views/DriveModeBottomCard.swift` (approaching strip extension INSIDE the existing `.safeAreaInset(edge: .bottom)` chain — NO new layer per OQ-1 to avoid #31 regression class); `Views/ArrivalPromptSheet.swift` (new — `ParkConfirmView`-pattern sheet with "Park Here" / "Not Yet" actions); `Views/ContentView.swift` (new `.onChange(of: driveModeDistanceMeters)` + `.onChange(of: finalApproachState)` handlers; new `ActiveSheet.arrivalPrompt(coord: CLLocationCoordinate2D)` case with `arrivalCoord` captured from `locationService.userLocation`; `arrivalPromptFired: Bool` one-shot gate for hysteresis at the 50m boundary; arrival-confirm closure does `parkPinService.save(car)` → `endDriveMode()` → `activeSheet = .parkUntil` — verified `endDriveMode` doesn't touch `activeSheet` so the assignment isn't clobbered). **Tests: 228 → 243/0** (+15 W85dTests: 13 from pass-1 + 2 from pass-2 invariant assertions for the auto-fire wiring; one 499m boundary test added beyond the spec inventory list). Spec: `docs/w8.5d-final-approach-spec.md` (691 lines, 6 OQs resolved as recommendations; AC-18 amended in pass-2 to reflect the auto-fire behavior). QA: pass-1 `docs/qa/w8.5d-pass-1-2026-05-31.md` (Ship with caveats; 1 Significant Finding #1 = stale AC-18 spec-vs-W7.5-as-shipped mismatch — code was correct, spec was stale; 1 Minor Finding #2 = inventory comment off-by-one) + pass-2 `docs/qa/w8.5d-pass-2-2026-06-01.md` (Ship; Finding #1 resolved via Option B auto-fire wiring; Finding #2 partially resolved — engineer's pass-2 comment correction had its own off-by-one, fixed post-merge inline). **All architecture preserved**: `MapViewRepresentable.swift` NOT touched (so the PR-3 region-sync fix is preserved by default; `RegionSyncGuardTests` 2/2 still pass); `.onChange`-driven only (no mutation inside `updateUIView`); no `setRegion` on Drive Mode active path; no headless-window guard; no `userTrackingMode` changes. **Kevin's manual smoke deferred for AC-25–28** (approaching-strip visibility, arrival-prompt fire point, "Not Yet" survives in Drive Mode, polish trilogy continues working during final approach) — sandbox cannot drive the multi-tap Drive Mode flow. NOT touched: `project.pbxproj`, `Info.plist`, `Config.xcconfig*`. |
| **W8.5c-polish PR-2** — auto-zoom + `.mutedStandard` map style + pitch re-eval to 45° + directional user puck (re-attempt, **part 3 of 3 — trilogy complete**) | ✅ merged (PR #34, `8f42e03`) | Final atomic polish PR completing the W8.5c-polish re-attempt trilogy. **Four features on the same Drive Mode entry/exit transition**, single combined `setCamera` for pitch + zoom (R-2 design-time risk eliminated). `Views/MapViewRepresentable.swift` (`driveModePitch` 30° → **45°** based on tighter-zoom MapKit clamping headroom; new `driveModeCameraSpan`/`altitudeForSpan` constants — `altitude = (span × 111_000) / (2 × tan(15°))` per spec §3.5; new `targetSpan(forDriveModeActive:priorSpan:)` + `targetMapConfiguration(forDriveModeActive:priorConfiguration:)` pure functions; extended `CoordinatorActions` with `applyDriveZoom`/`captureCurrentSpan`/`applyDriveMapStyle`/`captureCurrentMapStyle`; new `applyDriveCameraState` coordinator method does pitch + zoom in ONE `setCamera(animated: true)` call; new `applyDriveMapStyle` swaps `mapView.preferredConfiguration` to `MKStandardMapConfiguration(emphasisStyle: .muted)` on entry and restores on exit; directional puck via custom `MKAnnotationView` for `MKUserLocation` intercepted in `mapView(_:viewFor:)` with `syncDriveHeading` updating the puck's `transform`); `Views/ContentView.swift` (new `preDriveDistance`/`preDriveMapConfiguration` state vars; extended `handleDriveCameraChange` to capture/apply zoom + style + trigger puck refresh). **Tests: 214 → 228** (+14: 13 new `DriveZoomStyleTests` for the pure functions + 1 net updated `DriveCameraTiltTests` for the 30° → 45° constant). Spec: `docs/w8.5c-polish-pr2-spec.md` (367 lines, 3 OQs resolved — bundle puck mechanism (b), measure pitch empirically (deferred to Kevin's smoke due to sandbox limit), use `preferredConfiguration` API). QA: pass-1 `docs/qa/w8.5c-polish-pr2-pass-1-2026-05-30.md` — Ship with caveats, all architecture checks pass (`.onChange`-driven, single combined `setCamera`, no `userTrackingMode`, no headless guard, no `MKMapType`, no `setRegion` on Drive Mode active path, `RegionSyncGuardTests` 2/2 still pass — PR-3 fix preserved). 1 nit (`MKMapConfiguration` lacks `==` so `targetMapConfiguration` exit test can't fully assert object identity — inherent API limitation). **Kevin's manual smoke (2026-05-30) confirmed all 4 features visible and working**: auto-zoom to ~1-2 blocks, 45° pitch renders faithfully (NOT clamped at the tighter zoom — engineer's reasoned default was correct), `.mutedStandard` softens the base map and the parking polylines stand out more, directional puck arrow appears and rotates with heading. Real heading-up rotation untestable in sim (no magnetometer) — deferred to real-device drive-test. NOT touched: `project.pbxproj`, `Info.plist`, `Config.xcconfig*`. **The full W8.5c-polish re-attempt trilogy is now on main**: PR-1 (distance indicator + End Drive z-order) + PR-3 (3D tilt) + PR-2 (zoom + style + puck + pitch re-eval). Drive Mode visual experience is now substantially closer to Apple Maps drive view while staying within Option B parking-focus framing. |
| **W8.5c-polish PR-3** — 3D camera tilt on Drive Mode entry (re-attempt, part 2 of 3) | ✅ merged (PR #33, `adebdc2`) | Second of three atomic re-landing PRs. **Tilt to 30° on Drive Mode entry, restore prior pitch on exit, animated ~0.3s.** `Views/MapViewRepresentable.swift` (`targetPitch(forDriveModeActive:priorPitch:)` pure static func — no `MKMapView` dep, trivially testable; `CoordinatorActions` reference-type box `applyDrivePitch`/`captureCurrentPitch` wired in `makeUIView`; `applyDriveCameraPitch` coordinator method does `mapView.camera.copy()` + pitch=target + `setCamera(animated: true)`; NEW `driveModeActive: Bool` property; NEW `shouldSyncRegionToBinding(driveModeActive:)` pure func gating the region-sync; NEW `syncDriveRegion` pitch-preserving follow recenter); `Views/ContentView.swift` (`@State coordinatorActions = MapViewRepresentable.CoordinatorActions()`, `.onChange(of: driveModeActive)` → `handleDriveCameraChange` → `coordinatorActions.applyDrivePitch?` — camera mutation OUTSIDE `updateUIView`, the architectural fix for #31). **Tests: 207 → 214** (+7: 6 `DriveCameraTiltTests` + 2 `RegionSyncGuardTests` covering pure functions). QA: pass-1 `docs/qa/w8.5c-polish-pr3-pass-1-2026-05-28.md` (architecture verified, launch-state overlays render — no #31 regression, 1 non-blocking nit re: `altitudeForSpan` stub for PR-2 convenience). **Kevin's first smoke (2026-05-28)** caught a real bug QA missed: tilt didn't visually apply in sim because a latent W8.5c bug at `MapViewRepresentable.swift:381` — `if driveHeading == nil { setRegion(region, animated: false) }` — fired on every `updateUIView` in the sim (`driveHeading` always nil with no magnetometer) and `setRegion` resets camera to top-down, wiping the just-set pitch. The guard was inverted: meant to skip during Drive Mode but conflated "no heading yet" with "not driving." Pass-2 fix `4fb4f93`: added `driveModeActive` property, gated region-sync on `!driveModeActive` via the new `shouldSyncRegionToBinding` pure func, added pitch-preserving `syncDriveRegion` (via `setCamera`, not `setRegion`) for follow-during-drive. **Kevin's second smoke** confirmed the 30° tilt now visibly applies; overlays still render; toolbar/banner/bottom card intact. **Process win**: the new `.onChange`-driven architecture (PR-3's whole point) is sound — the bug was downstream, in a guard that had been wrong since W8.5c but only manifested when something tried to set pitch. The architectural pattern, the test discipline (pure-function decisions for camera invariants), and the live-UI smoke gate (which caught the launch-state regression check) all worked together. **The bug was caught the only way it could be — by Kevin's manual Drive Mode smoke, since the sim sandbox can't drive the destination-search multi-tap flow headlessly.** Lesson: for camera/animation changes, Kevin's manual smoke is irreducible verification — tests + agent smoke cover the regression check but not the visual-application check. NOT touched: `project.pbxproj`, `Info.plist`, `Config.xcconfig*`. Spec at `docs/w8.5c-polish-pr3-spec.md` (300 lines, 3 OQs resolved, in the PR diff). Next: **PR-2** (auto-zoom — original) **expanded**: re-evaluate pitch at the new tighter zoom (MapKit may allow 45–60° without clamping), `.mutedStandard` map style swap, possibly directional user puck. |
| **W8.5c-polish PR-1** — distance indicator + End Drive z-order (re-attempt, part 1 of 3) | ✅ merged (PR #32, `29dfe27`) | First of three small atomic PRs re-landing the reverted W8.5c-polish, each gated by a mandatory live-UI smoke before merge. PR-1 = the two SAFE pure-SwiftUI pieces (no camera code). `Views/DriveModeBottomCard.swift` (distance-to-destination indicator top-right of street-name row via `CLLocation.distance(from:)` + `MeasurementFormatter` honoring `Locale.current.usesMetricSystem`); `ContentView.swift` (End Drive pill z-order: `paddingForBannerState(_:)` pure function returns 44pt for all 3 banner-visible states so the pill clears the always-on ASP banner; `@ViewBuilder` extraction of `driveModeOverlayLayer`/`bottomSafeAreaContent`/`sheetContent` to stay under the Swift type-checker complexity limit — verified behavior-preserving). **Tests: 196 → 207** (+11; recovered DistanceFormattingTests + EndDrivePillLayoutTests from the reverted commit, NOT the camera tests). QA: pass-1 `docs/qa/w8.5c-polish-pr1-pass-1-2026-05-28.md` (1 blocker: `endDrivePillTopPadding` returned 0 for `.aspInEffect`, a visible-banner state — z-order inversion), pass-2 `docs/qa/w8.5c-polish-pr1-pass-2-2026-05-28.md` (SHIP — fix `7408fe6`, orchestrator-executed after qa sub-agent socket-dropped post-screenshot). **The new live-UI smoke gate worked**: both engineer + QA captured sim screenshots + `Read` them to confirm the overlay layer renders — no recurrence of the #31 regression. **Kevin's manual smoke (2026-05-28)** confirmed: distance indicator shows "1.9 mi", End Drive pill clears the red ASP banner at 44pt with Drive Mode active. NOT touched: `MapViewRepresentable.swift`, `project.pbxproj`, `Info.plist`, `Config.xcconfig*`. Next: **PR-3** (3D tilt at 30°, the #1 product value), then **PR-2** (auto-zoom). Both re-implemented with camera changes driven by `.onChange(of: driveModeActive)` OUTSIDE `updateUIView` (the suspected #31 root cause) and NO headless-window guard. |
| **W8.5b** — Destination input + routing UI + parking-aware scoring | ✅ merged (PR #29) | `Views/DriveModeDestinationView.swift` (new — `MKLocalSearchCompleter`-backed search inside a full-screen cover, recent destinations list (5 entries, MRU, swipe-to-delete, `UserDefaults`-backed `RecentDestinationsStore` defined inline — see N-1 advisory below), "Start Drive" button as the W8.5c activation seam, inline `errorBanner` for `MapboxRouteError` cases, out-of-coverage toast via `ToastService`); `Services/RouteService.swift` (new `pickBestParkingAwareRoute` static method — direct port of `index.html:6298–6340`: skip set noStanding/noParking/special/truckLoading/unknown, stride sampling ~60 pts, 30m `CLLocation.distance` radius (strictly more accurate than the PWA's manual equirectangular approx), free=+3 / metered=+1, duration penalty `score -= duration/600`, block key dedup `street|from|to`, empty→nil, single→primary, tied→primary); `Views/ContentView.swift` (`arrow.triangle.turn.up.right.diamond.fill` 4th toolbar button, `fullScreenCover` presentation, `activeRoute`/`destinationCoordinate`/`driveModeActive` state, `activeSheet == nil` guard, End Drive pill); `Views/MapViewRepresentable.swift` (`RoutePolyline` overlay with `.systemBlue` stroke, `DestinationPinAnnotation` with `mappin.circle.fill` in `.systemRed`, S-1 fix: route polyline re-inserts above parking overlays after `applyOverlayPayload` to preserve Z-order on tile reloads); `Services/Constants.swift` (new constants). M-1 fix: `MKLocalSearch.start` wrapped in `withThrowingTaskGroup` race against `Task.sleep` for 10s timeout. **Tests: 149/0** (+21 W8.5b core tests +2 pass-2 tests: `testRoutePolyline_zOrder_preservedAfterOverlayRebuild` exercising real `MKMapView` overlay machinery, `testResolveAddress_searchTimeout_setsErrorAndClearsResolvingState` with nanosecond-shortened timeout). Spec: `docs/w8.5b-destination-routing-spec.md` (538 lines, 8 OQs resolved as tech-lead recommendations). QA: pass-1 SHIP WITH FOLLOW-UPS at `docs/qa/w8.5b-pass-1-2026-05-20.md` (S-1 + M-1 + N-1 + M-2), pass-2 SHIP CLEAN at `docs/qa/w8.5b-pass-2-2026-05-20.md` (S-1 + M-1 resolved). **W8.5a M-1 advisory (`@MainActor` propagation) resolved** — test class annotated `@MainActor` and call sites use structured concurrency correctly. Smoke (Kevin, Penn Station GPS, 2026-05-23): destination search → route fetch → blue polyline render → destination pin all work end-to-end; "proper drive mode" UX (continuous location, voice, heading-up) is W8.5c scope by design. |
| **W8** — TestFlight build | ⏸️ blocked on Apple Developer Program | Enrollment still pending as of 2026-05-11. |

**Carry-over deferrals (not blocking next stream):**
- **Real-device memory + FPS measurement.** New memory acceptance criterion from W4 decision doc §5: peak simulator RSS < 500 MB after 5 min of Manhattan panning, zero Metal pruner assertions. Currently measured at 137.5 MB simulator RSS post-refactor. Real device measurement requires Apple Dev approval (W8 blocker). Replaces the older FPS-only R1 stress test which was never run and turned out to be the wrong proxy anyway.
- Live PWA-captured parity tests (W3 QA finding #3). Engine's `safetyLabel` strings are reasoning-checked; could diverge in subtle locale/format ways from real PWA output. Recommend a small "live snapshot" PR pre-W8.
- Tile resource folder reference (Xcode) vs synchronized group. Build time is no longer the binding constraint (the rendering bottleneck is fixed), so this is now a nice-to-have rather than a near-term need.
- W3 QA minor findings (#6, #7) — informational/deferrable cosmetic items.
- W4 QA pass-2 minor findings — see `docs/qa/w4-pass-2-2026-05-11.md`.
- W4.5 QA pass-1 nits (blank decision-log column in palette doc) — see `docs/qa/w4.5-pass-1-2026-05-11.md`. Cosmetic.
- W5 unit tests for `ParkPinService` round-trip + `findCandidateSegments` haversine — W5 QA Finding #3, optional. No regression risk; deferred. Worth doing during W6 or W7 if engineer has bandwidth.
- **Sign text truncation in `BlockDetailView` rule list.** ~~Kevin caught during W5.1 smoke (2026-05-13)…~~ **Closed** 2026-05-15 via W7 §3.D — `RuleRow` is now tap-to-expandable in both `BlockDetailView` and `ParkedCarDetailView` (fix propagates since `RuleRow` is `internal`).
- **Polyline intersection geometry artifacts** — addressed 2026-05-13 / 2026-05-14 via PR #21 (6m setback) and PR #22 (10m setback + butt line caps + iOS Resources sync). See `docs/tile-geometry-investigation.md` and `docs/qa/tile-intersection-clip-pass-{1,2}-2026-05-14.md`. Closed.
- **W6.1 — deep-link tap → ParkedCarDetailView presentation flake.** ~~Kevin's W6 smoke confirmed: notifications schedule + fire + tap brings app to foreground correctly, BUT the `ParkedCarDetailView` sheet doesn't reliably present from the tap…~~ **Closed** 2026-05-16 via PR #25 (`3c3ea10`). Root cause: `notificationDeepLinkSubject` was a `PassthroughSubject` (no replay); on cold-kill / deep-background wake, SwiftUI subscriber wasn't attached when the delegate fired → event dropped. Fix: replaced with `@Published var pendingDeepLinkCarID: UUID?` on `AppDelegate` (now `ObservableObject`), with dual-path routing — `.onChange(of: pendingDeepLinkCarID)` for foreground/background-wake AND `.onChange(of: scenePhase) { .active }` for cold-kill (since iOS 17's `.onChange(of:)` doesn't fire on initial value). `routePendingDeepLink(_:)` helper clears the buffer before routing (idempotent). Kevin's smoke 2026-05-16 confirmed all 3 critical scenarios pass: background-wake, cold-kill (the original W6 failure), and mismatched-carID negative test. Tests: 79/0 (+7 W6.1 tests, including a real scenePhase cold-kill test and a real mismatched-carID test). Spec/diagnosis: PR #25 body. QA: `docs/qa/w6.1-pass-1-2026-05-15.md` (SHIP WITH CAVEATS — only test-quality nits, addressed in pass-2 commits `71552f9` + `504e755`).
- **Per-pin notification opt-in toggle.** ~~Kevin's W6 feedback (2026-05-14)…~~ **Closed** 2026-05-15 via W7 §3.C — `ParkedCar.notifyOnRestriction: Bool` (defaults `true`, decodes safely for pre-W7 pins). Toggle in `ParkConfirmView` defaults ON; editable in `ParkedCarDetailView` round-trips through `ParkPinService.updateNotifyOnRestriction(_:)`. `NotificationScheduler.schedule(...)` guards per-pin opt-out AFTER global mute.
- **Notifications for metered + other categories.** Currently `computeNextRestrictionHours` filters out METERED (so no "your meter expires" reminders) and other categories. Kevin asked about expanding (W6 smoke, 2026-05-14). Post-MVP — not a v1.0 priority since free parking is the core value prop. Owner: `@backend-data` + `@ios-engineer` co-design.
- **Degenerate sub-segments in tile data.** Per W6 / tile-PR-pass-2 QA: ~6.8% of segments (~2,670) have `line[0] === line[-1]` after the 10m setback (was 1.5% at 6m). Pre-existing data-quality issue in `extractSubSegment` where sub-zones near intersection edges collapse to a point under aggressive trimming. Renders as invisible / no impact, just wasted bytes. Owner: `@backend-data` — small fix to add a degenerate-skip filter in the sub-segment emission loop. Not urgent.
- **SW cache bump** for the merged tile changes (PR #21 + PR #22). ~~`sw.js` `CACHE_VERSION` `wepark-v32` → `wepark-v33`. Pending.~~ **Closed** 2026-05-15 via PR #23 — live PWA clients evict pre-PR-#21/#22 caches on next visit.
- **VoiceOver swipe-through-blocks on the map** (not in the sheet) — dropped in W4 fix-pass-1 (Option A from decision doc): the `Annotation` per segment was unscalable. In-sheet a11y is fully intact. Post-MVP: lightweight `MKAnnotation` at reduced density is the proper path.
- **Terms of Service / Privacy Policy copy.** Kevin's W7 decision (OQ-W7-1): he wants legal links in the Settings footer eventually but has no URL or copy yet. `SettingsView` currently shows version + build only (no `termsURL` constant, no `Link` row). Owner: Kevin (non-engineering — needs legal copy / hosted URL). Add to `SettingsView` once copy exists; `Constants.swift` gets a `termsURL`, `SettingsView` gets a `Link` row in the existing About section.
- **Viewport polish — hide overlays at wide zoom + auto-center at launch.** ~~Kevin caught during W6.1 smoke (2026-05-16): patchwork overlay rendering at wide zoom…~~ **Closed** 2026-05-16 via PR #26 (`4264e60`). Part A: `polylineHideSpanThreshold` lowered `0.1 → 0.04` (overlays cleanly hide at wide zoom; clean Apple Maps basemap visible). Part B: 3-priority auto-center at launch — (1) deep-link → parked car coordinate (no coverage check); (2) authorized + cached in-coverage location → snap immediately, refresh on fresher fix; (3) fallback → `manhattanCenter`. `AppConstants.isInManhattanCoverage(_:)` uses the actual tile-grid bounding box (40.700–40.882 N, -74.020 to -73.907 W) from `tiles/index.json` — Hoboken / Yonkers / JFK correctly fall outside; Roosevelt Island + DUMBO are inside (spec-accepted). Pass-3 follow-up fix: `routePendingDeepLink(_:)` also recenters camera (was only setting `activeSheet`) — caught by Kevin's smoke #5 because the `.task` Priority 1 branch can fail on cold-kill timing race (delegate sets `pendingDeepLinkCarID` AFTER `.task` evaluates). Tests: 79 → 96 (+17 new viewport tests: coverage bounding-box including 4 lng-boundary edge cases). QA: `docs/qa/viewport-polish-pass-1-2026-05-16.md` (SHIP WITH CAVEATS, all polished in pass-2 + pass-3).
- **Polyline tile-load latency on deep-link cold-launch (UX nit, not regression).** Kevin's smoke #5 with viewport-polish (2026-05-16): after the camera snaps to the parked car block, polylines take ~2-3s to render (user sees Apple Maps + car icon, then overlays pop in). Root cause: `TileLoader.loadTiles(forRegion:)` is async and fires for the OLD default region first; when the camera jumps to the parked car region, tiles for the new area need to fetch + parse separately. Pre-viewport-polish this wasn't visible because the camera stayed wide-zoom (overlays hidden anyway). **This is the exact case the dynamic-tile-loading-on-pan work would fix** — already deferred to post-W8 per `docs/viewport-polish-spec.md` §9. Owner: `@ios-engineer` post-W8. ~1-2 sessions. Worth noting because the new viewport-polish camera behavior makes the existing infrastructure limitation more user-visible.

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
- **Phase 5**: iOS launch — **Swift native + TestFlight** (decided 2026-05-07; in active development since 2026-05-08). MVP streams W1a, W1.5, W2, W3, **W4, W4.5, W5, W5.1, W6, W6.1, W7, viewport-polish, W7.5, W8.5a, W8.5b, W8.5c, W8.5c-polish PR-1 + PR-3 + PR-2 (trilogy complete), W8.5d (final approach + arrival + W7.5 auto-fire)** are merged to `main`. (Full W8.5c-polish merged + reverted same-day 2026-05-26 due to live UI regression; re-landed as 3 atomic PRs gated by live-UI smoke — see Changelog.) Destination-mode Drive Mode is now feature-complete. Next: real-car drive-test (the long-pending carry-over since 2026-05-01 — unblocks calibration of voice frequency, font sizes, the 4s gap, the 50m arrival threshold, and the Option B+ maneuver hint product question), then W8.5c-follow voice calibration + Option B+ maneuver hint decision, then patrol mode W8.5e–i, then W8 TF1., plus 3 PRs against tile / SW pipelines (#21 + #22 intersection-overshoot fix, #23 SW cache bump). See "Phase 5 progress" table above for stream status. **Apple Developer Program approved 2026-05-17** (W8 unblocked). **Roadmap pivot 2026-05-17:** Kevin decided to bring W8.5 (Drive Mode) INTO the MVP/TF1 instead of shipping a pre-Drive-Mode TF1 then a TF2-with-Drive-Mode. Single complete-vision launch. New order: **W8.5 (Drive Mode, 9-13 sessions broken into sub-PRs W8.5a-f per `docs/drive-mode-scope-spec.md` Option B + patrol mode) → W8 (TF1 with full vision, no W9 needed)**. **W8.5a foundation merged 2026-05-20** (PR #28 — Mapbox HTTP Directions + RouteService). **W8.5b merged 2026-05-23** (PR #29 — destination input + routing UI + parking-aware scoring; 149/0). **W8.5c merged 2026-05-24** (PR #30 — Drive Mode active layer with continuous location + heading-up rotation + voice + commentary engine; 196/0). **W8.5c-polish merged 2026-05-26 then REVERTED 2026-05-26** (PR #31 — Apple-Maps-isms: auto-zoom + 3D tilt + distance indicator + bottom card doc + End Drive z-order; 210/0 tests passed but live SwiftUI overlay layer broke; reverted via `8036d25`). New spec-fidelity norm stays at `.claude/agents/ios-engineer.md` (separate commit `445e4a3`, not part of the revert). Next: **W8.5d** (final approach + arrival prompt → W5 pin-drop hook; ~1 session), then drive-test, then W8.5c-follow voice calibration, then patrol mode W8.5e–i. Post-MVP follow-on phases: threat tracker UI, zone chat, Smart Move recommendations, address search, snow emergency / NYC 311 API, paywall + StoreKit (see `docs/business-model.md`).
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

## Environment split: Linux VPS vs Kevin's Mac (since 2026-08-10)

The repo runs in two places. **Detect where you are** (`uname` / hostname: `openclaw-sandbox` =
the DigitalOcean VPS at 167.172.237.2, `/root/repos/parkmap`; Darwin = Kevin's MacBook,
`/Users/kevinhoxha/repos/parkmap`) and behave accordingly:

- **VPS (Linux — phone-driven sessions):** full capability for specs, tech-lead/QA agents, the
  entire tile/data pipeline (`node build/preprocess.js`, `scripts/coverage-report.js`), Supabase,
  docs, git/PR management (`gh` authed). **NO Xcode, NO simulators, NO archive.**
- **Mac (Darwin):** everything, including `xcodebuild` test runs, simulator live-UI smoke gates,
  cold Release builds, and the Archive → TestFlight ceremony.
- **The working protocol for Mac-only steps while Kevin drives from the VPS/phone:** do NOT block
  or skip — emit the exact commands for Kevin to paste into his MacBook terminal (one fenced
  `bash` block per command, self-contained, no placeholders), he runs them manually and pastes
  back the output. Alternatively Kevin will say "we're on the Mac now" when he switches to a Mac
  session — treat that as the environment flipping, not a new project.
- Both checkouts push/pull through GitHub (`kevhox1/parkmap`) — always `git pull` at session
  start; never assume the other machine's checkout is stale-free.

## Changelog

### 2026-08-22 — 🎉 FT-20 COMPLETE. Build 17's payload is done; version bumped to 17.

**`main` @ `7d90595a`+. Zero open PRs. `CURRENT_PROJECT_VERSION` = 17.** Build 17 = dark mode (#83) +
realtime WebSocket (#84) + the FT-20 browse-mode bottom sheet (#85, #86, #87). Kevin's Mac:
**804 passed, 0 failed.** Full live smoke passed — *"I think it all looks good."*

**What shipped in the sheet:** peek shows the search field alone (map keeps ~90%); a `gearshape`
Settings affordance in the search field's trailing edge (Apple Maps' avatar position); one primary
`car.fill` **"Find a Spot"** button; a quiet "New to parking?" link. Search → place state (distance +
"Parking near here" in semantic green/amber/red) → **Go**. Top-right went from FOUR floating buttons
to THREE (Find me / Find my car / Park Until). `DriveModeDestinationView.swift` deleted entirely.

**🔴 THE SIX-ROUND BUG, AND THE PROCESS LESSON THAT MATTERS MOST IN THIS DOC.**
Peek would not render correctly across **six** build-and-smoke cycles. Every fix was locally correct
and none moved the symptom: a real `grabberAndInsetAllowance` double-count (24→12), a structural clamp
below `actionContentTopOffset`, conditional rendering of the action column, `listSectionChromeAllowance`
deleted with the `List`. The symptom kept *moving* — Settings bleeding in, then the third row clipped,
then the search field vanishing entirely.

**The actual cause:** `BrowseSheetSearchAreaHeightPreferenceKey.reduce` was `value = nextValue()` —
"last write wins" — which violates `PreferenceKey`'s contract that `defaultValue` be the reduce
operator's **identity element**. SwiftUI invokes `reduce` once per sibling branch *including branches
that never call `.preference()`*; those contribute `defaultValue` (0) and silently overwrote the real
measurement. **`searchAreaHeight` was `0.0` in every single round.** Four rounds of height arithmetic
were performed on a number that was always zero. Replaced with `.onGeometryChange` (iOS 17+, target is
17.0), which has no cross-tree aggregation, so the bug class is structurally impossible rather than
merely avoided.

- **⭐ RULE: when two consecutive well-reasoned fixes don't move a symptom, STOP REASONING AND
  INSTRUMENT.** A `#if DEBUG` overlay printing the live values found in ONE screenshot what four rounds
  of static analysis could not. Cost: minutes. Saved: an unbounded number of build cycles.
- **Tests can pin a bug as intended behavior.** Two tests asserted the broken last-write-wins `reduce`
  was correct. Hand-feeding `reduce` in isolation cannot reproduce a bug about how many times SwiftUI
  invokes it across a live tree — so they passed while the feature was broken. Deleted, with reasoning.
- **The diagnostic became a cause.** The debug overlay was itself a preference-less sibling branch
  contributing `0`. Worth knowing that instrumentation can perturb what it measures.
- **A custom `.height()` detent is a real layout constraint, not a crop window.** Fixed-height siblings
  win the space negotiation and starve the only flexible child. That's why the search field vanished
  while the button still rendered.
- **`car.front.waves.right.fill` is not a real SF Symbol** — the `car.front.waves` family has `.up`,
  `.down`, `.left.and.right.and.up`, but no `.right`. It had been silently blank since
  `driveEntryButton`, invisible inside a menu. Verify SF Symbol names; an unresolved one renders empty
  and collapses its `Label`'s text alignment.

**Serialized-PR discipline paid off twice.** Stream A merged **gated OFF** (`ft20BrowseSheetEnabled`)
after QA caught that its exhaustively-correct dismiss sweep was a **trap state** in the intermediate
build — every dismissal landed in a non-dismissible sheet, force-quit the only exit. Stream B then
*refused* the spec's instruction to gut `DriveModeDestinationView.swift`, because that file was still
the live search path. **Code correct for the END state can be a trap in an INTERMEDIATE state; when a
feature is serialized across PRs, the intermediate states are their own acceptance criteria.**

**NEXT:** Kevin archives 17 → TestFlight → drive test. That drive is also the gate on build 18
(patrol mode), which must not start until realtime has been proven on a live socket in Manhattan.

---

### 2026-08-20 (later) — FT-20 Stream A merged, gated OFF. Sheet container exists but is invisible.

**`main` @ `37aa8c01`. Zero open PRs.** Kevin's Mac: **748/748 passed, 0 failed, 0 skipped** (iPhone
17 / iOS 26.5) — exactly +18 over the 730 baseline, matching the 18 new test functions on the branch,
so every new test demonstrably ran. **Live smoke passed.**

**⚠️ THE ONE THING A FUTURE SESSION MUST NOT MISS: `ft20BrowseSheetEnabled` is `false`.** Stream A is
merged but **completely inert** — no user can see the sheet. `.browseNav` is unreachable. This was
deliberate, and **Stream C owns flipping it**, in the same change that lands the cold-launch mount,
the Drive-Mode boundary (AC-28/29a) and the FT-15 block-select boundary (AC-23–27/S4). The gate's own
doc comment says so; grep `ft20BrowseSheetEnabled`.

**🔴 WHY THE GATE EXISTS — QA pass 1 caught a trap state that would have shipped.** Stream A's
dismiss-site sweep was *exhaustively correct for the end state*: every sheet dismissal routes to
`.browseNav`. But Stream C wasn't there to mount the sheet, so in the intermediate state every
ordinary dismissal — Settings, ParkConfirmView Cancel, ParkUntil Skip, Parking-101 Done — landed the
user in a `.interactiveDismissDisabled(true)` sheet containing only a placeholder, with nothing ever
clearing it. **Force-quit was the only exit.** Repro: long-press → "Park my car here" → Cancel.

**The lesson is sharper than "QA caught a bug":** every piece was individually correct, and the
author's own doc comment asserted `.browseNav` was "unreachable until Stream C lands" — a **false
invariant stated as fact**, which is exactly what made it invisible to self-review. When serializing
a feature across PRs, the intermediate states are their own acceptance criteria. The fix's bar was
*"merging this must be a user-visible no-op,"* and QA pass 2 proved that semantically against `main`
rather than spot-checking.

**Also fixed in the same pass:** two stale `guard activeSheet == nil` blocking guards — the old
"Drive to a destination" menu item and, more seriously, the in-Drive **"Park here"** button, a
safety-relevant action that would have silently no-op'd once the gate flipped.

**Design review earned its keep before any code existed.** It found that spec §4.1's own code sample
used system `.medium` as the middle detent — contradicting Kevin's OQ-3 ruling at the top of the same
document — and all 11 pre-existing `.presentationDetents` sites in `ContentView.swift` use `.medium`,
so both the spec and the local convention pointed at the outcome Kevin explicitly rejected. Corrected
in the spec with the trap named inline. Its six Significant findings were folded into the build as
spec §0b rather than deferred.

**NEXT:** Stream B (search/place relocation + Go + the "parking near here" summary) → Stream C
(integration + flip the gate) → QA → bump to 17 → archive → drive test.

---

### 2026-08-20 — 🚀 WEPARK IS PUBLIC. Build 16 passed Beta App Review; external TestFlight link is live.

**Kevin is no longer the only user.** Build 1.0 (16) cleared Apple's Beta App Review and is
distributed externally via a **public TestFlight link**. This is the first time anyone outside Kevin
has run WePark.

**🔴 THE STANDING ASSUMPTION THAT JUST DIED.** From 2026-08-13 to 2026-08-20 the docs said, in four
places, *"Kevin is the ONLY TestFlight user — breaking changes stay cheap until an external group
exists,"* with an explicit instruction to revisit it the moment that group existed. **It exists.**
Consequences, in order of how easy they are to forget:
- **Breaking changes now cost real people their data.** Data migrations, session resets and
  state-dropping schema changes were free; they aren't now.
- **The anonymous identity is load-bearing for strangers.** `SupabaseAuthService` reasons that "the
  worst case on upgrade is a fresh anonymous identity" — costed against one user who could shrug it
  off. An external tester who loses their session loses their saved car and their report history,
  **with no account to sign back into.** That is now a real product risk, not a shrug.
- **Migration shims stop being hypothetical.** The old "don't build them" advice was right at the
  time and banked a real saving on realtime Stream A. Decide per change now.
- **Nothing polls TestFlight crash reports or feedback.** No tooling, no alerting. Worth a habit.
- **FT-21 (mid-road lines on wide streets) and the ~50% coverage gap are now visible to strangers.**
  Both are named as known issues in the What-to-Test copy specifically to suppress duplicate reports.

**What external testers are getting:** build 16 — FT-15 film-shoot reports, FT-18's Bottom Dock,
FT-17a Recenter, the FT-14/FT-19 geometry fixes, Parking 101. **NOT dark mode and NOT realtime** —
those are build 17, still in progress. So the first external impression is the light scheme and the
8-second poll.

**Beta App Review notes worth keeping for next time:** the app has **no user-facing sign-in**
(`signInAnonymously()` runs silently, there is no LoginView), so App Store Connect's "Sign-in
required" box must be **unchecked** — checking it makes the reviewer expect credentials that don't
exist. And because coverage is NYC-only, the review notes explicitly tell the reviewer to simulate
Manhattan (40.7250, -73.9900); a reviewer in Cupertino sees an empty map and can reasonably call the
app broken.

**Build 17 is unaffected and continues** — one item from done (the FT-20 sheet).

---

### 2026-08-19 (later) — Realtime Stream B MERGED. Build 17 is now one item from done.

**WHERE WE ARE:** `main` @ `5d4604a6`. **Zero open PRs.** `CURRENT_PROJECT_VERSION` still **16**.
Build 17's payload: dark mode ✅ (#83) + realtime ✅ (#84) + **FT-20 bottom sheet ⬜ — the only
thing left.**

**✅ PR #84 — supabase-swift Stream B, real WebSocket Realtime.** Replaces the 8s poll with a
table-wide `public.pins` subscription; poll retuned 8s→45s as a silent-failure backstop. New
`RealtimePinChannel.swift` (the only file importing `Realtime`) + `RealtimeMergeGate.swift`.
`MapViewRepresentable.swift` zero diff; `ContentView.swift` a 52-line `scenePhase`-only change,
deliberately small because the FT-20 sheet lands in that same file next.
**Kevin's Mac: 730/730 passed, 0 failed, 0 skipped** (iPhone 17, iOS 26.5) — first try, no compile
errors, on Swift written blind with no toolchain on the VPS.

**🔴 THE FINDING THAT JUSTIFIED THE PROCESS — QA pass 1 caught a lifecycle race.**
`startRealtime()` cancelled `realtimeConnectTask` but never awaited an outstanding
`realtimeDisconnectTask`; `Task.cancel()` is cooperative and `connect()` never checked
`Task.isCancelled`. On a fast background→foreground flap the trailing `disconnect()` could land
*after* the new `connect()`, and `connect()`'s own idempotency guard would read a stale
`.subscribed` and skip re-subscribing. **End state: the service believes Realtime is live, the
socket is dead, nothing self-detects it** — and it compounds with the Drive-Mode poll suspension,
so pins freeze silently at 30mph. Fixed by chained-Task serialization (each lifecycle op awaits its
predecessor). QA pass 2 independently traced the causal chain and confirmed the stale-status window
is now *structurally unreachable*, not merely narrowed, and specifically hunted for the failure
modes chaining introduces (unbounded retain, self-await deadlock, stranded work) and found none.

**Deliberate trade-off now in the code, worth remembering:** rapid multi-flapping now **serializes**
(sum of round-trips) rather than racing. Always eventually correct, occasionally a beat slower. If
anyone ever reports pins taking a moment to catch up after switching apps repeatedly, that's this.

**PROCESS NOTES:**
- **A green total is not proof the new test ran.** Verified `testDisconnectThenReconnectFlap_…`
  exists on the branch *and* that the run reported 0 skipped, before believing the race was covered.
- **Verify a post-compile push is docs-only before merging on an earlier compile.** QA pass 2's
  report commit landed after Kevin's test run; diffed `0000b636`→tip to confirm zero code change.
- **Kevin's Mac has no iPhone 15 simulator** — it's the iPhone 17 family on iOS 26.4.1/26.5, each
  device present at *both* OS versions. Pass a **UDID** to `-destination`, never a bare name.
- **`docs/open-items.md` had gone six days stale in its top half** while its lower half was kept
  current, and `field-testing-log.md`'s FT-20 `Status:` line still read "BACKBURNERED … do not
  pre-empt it" under an ACTIVE header. Both fixed (`f4e0b259`). Re-stamp the snapshot date and prune
  closed rows in the same commit that closes them.

**✅ FT-20 DECISIONS RE-CONFIRMED BY KEVIN 2026-08-19** — all six design decisions and all four OQ
rulings still stand. Note he recalled the top-right as two icons (locate chevron + find-my-car key);
it is **three** — Park Until joins them per his own OQ-2 ruling. He confirmed on being told.

**NEXT:** FT-20 sheet (design review → A → B → C → QA) → bump to 17 → archive → drive test.
Then build 18 = patrol mode, gated on that drive proving realtime holds.

---

### 2026-08-19 — CHECKPOINT. Build 16 shipped + drive-tested; FT-15 complete; dark mode in; build 17 underway

**WHERE WE ARE:** `main` @ `8b2840aa`. **Zero open PRs.** Build **1.0 (16) is live on TestFlight,
installed, and DRIVE-TESTED.** `CURRENT_PROJECT_VERSION` is **16**; build 17 has not been cut.
**One agent running: realtime Stream B** (`@ios-engineer`, no branch pushed yet).

**🗺 BUILD PLAN (decided 2026-08-19, Kevin agreed to the split):**
- **Build 17 = dark mode (merged) + realtime WebSocket (in flight) + FT-20 bottom sheet (next).**
- **Build 18 = patrol mode / smart parking route.**
- Why split: `docs/smart-parking-route-2.0-concept.md` says don't start patrol until the realtime
  foundation is **solid**, and *merged is not solid* — it means Kevin has driven Manhattan on a live
  socket. Patrol mode is also a different **product behaviour**, judged by actually hunting a spot,
  so it deserves its own drive test. Build 13 became unshippable because too much landed at once.
- **Sequencing inside 17: realtime Stream B → then the FT-20 sheet.** Both touch `ContentView.swift`
  (Stream B only a `scenePhase` branch, the sheet a large diff) so they are **serialized**.

---

**✅ BUILD 16 DRIVE TEST — 2026-08-19. Four long-standing items closed on real hardware:**

| Item | Kevin | Note |
|---|---|---|
| **FT-19** | *"Lines look good"* | Lines stop short of intersections |
| **TF2-4** | *"Yes it's good now"* | **Open since 2026-06-08.** Cause was the setback coordinate mismatch (~32.8ft off), not side-assignment or NYC data |
| **TF2-19** | *"Metered"* | **Open since 2026-07-09** — the finding that scrapped build 13 and forced the fail-closed completeness gate |
| **TF2-18 sunlight** | *"Yes you can read it in the sun/daytime"* | ⚠️ Resolved **on the light scheme** — so dark mode is for *cleanliness*, NOT a legibility fix, and must not regress this |
| **FT-12 Parking 101** | *"it's there and it's good"* | |

**Still unverified after that drive:** **TF2-16** (heading at intersection approaches — Kevin: *"Unsure"*,
he didn't watch for it) and the **FT-15 end-to-end submit** (writes to production; do it somewhere
verifiable). **FT-21** (wide-street curb offset) was **re-confirmed as still broken** while driving —
*"lines are misaligned/placed. They appear in the middle of the road."*

**✅ FT-15 IS COMPLETE AND SHIPPED.** Streams A (schema, applied to prod), B1, B2, B3, B4 all merged.
Tap blockfaces → photograph the placard → submit → anyone parked there sees a restriction banner.
Kevin used the tap-select on-device. Known limitation recorded in the spec §13b: **selection
granularity is the whole blockface**, which over-reports when only part of a block is affected —
accepted because it errs toward caution, and film permits work in whole-block units anyway.

**✅ DARK MODE MERGED (#83).** Deliberately tiny: 66 insertions, **zero colour values changed**.
`UIUserInterfaceStyle: Dark` in `Info.plist` + `.preferredColorScheme(.dark)`. `ParkingColors` was
**audited, not edited** — restraint that was correct given Kevin had just confirmed daylight
readability on the existing palette. Kevin smoked it: *"Everything looks good."*

**🟡 FT-20 — all decisions settled, spec written** (`docs/ft20-bottom-sheet-navigation-spec.md`):
system `.sheet` (not hand-rolled), Park Until stays top-right as a floating map control, a **custom
detent** sized to search + three rows (not `.medium` — *WePark's map IS the product*), and search →
place → **Go** rather than auto-entering drive. Includes a **"parking near here"** summary in the
place state, which is deliberately the **first step of patrol mode** — factor its scoring as reusable
logic, not a one-off chip. Sizing: **4.5–6.5 iOS sessions**, expect a follow-up round.

**⚪️ BACKBURNERED:** **FT-21** (wide-street curb offset — Kevin wants an architectural decision about
how offsets are derived, not a fifth incremental tweak) and **FT-16a** (alerting for the staleness guard).

**PROCESS LESSONS ADDED:**
- **VERIFY `git branch --show-current` BEFORE EVERY COMMIT.** An agent dispatched *with* worktree
  isolation still left its branch checked out in the main checkout, and an orchestrator commit landed
  on it silently. The existing mitigation was insufficient. (Recovered via cherry-pick + rebase.)
- **Update the docs BEFORE dispatching when a standing instruction changes.** An agent correctly
  *refused* to start dark mode, citing three source-of-truth files that still said "do not start"
  after Kevin had lifted the backburner in conversation. Right behavior by the agent; the fault was
  dispatching against stale docs.
- `let` with a default value is **excluded from Swift's synthesized memberwise initializer** — broke a
  compile that a QA read had missed.
- Use `git checkout -B <branch> origin/<branch>`; a plain `checkout` of an existing local branch gave
  Kevin a stale build to smoke-test once.
- `xcodebuild test | tail` misses the summary — use `xcrun xcresulttool get test-results summary`.
- A transient `FBSOpenApplicationServiceErrorDomain … RequestDenied` mid-run is a stale simulator app
  instance; `TEST SUCCEEDED` after it is real — confirm via the xcresult count.

**NEXT:** realtime Stream B lands → Kevin compiles → merge → FT-20 sheet → bump to 17 → archive →
drive test. Then build 18 = patrol mode.


### 2026-08-18 — burn-down COMPLETE except one PR: FT-15 feature-complete, geometry regen shipped

**WHERE WE ARE:** `main` @ `39230d58`+. Build **1.0 (15)** still the newest on TestFlight; `CURRENT_PROJECT_VERSION`
is **16** and the archive is still **HELD** — deliberately. **One PR open in the entire project: #82.**

**🔑 KEVIN'S DIRECTIVE (still in force):** clear every open item before starting new work; ship ONE build
rather than dribbling them out. The board is `docs/open-items.md`. He had no car access 2026-08-14→~18,
which is exactly why holding the build cost nothing and bought a much better payload.

**🔑 Kevin is the ONLY TestFlight user.** Breaking changes stay cheap until an external group exists.

---

**MERGED THIS STRETCH (all verified, most on-device):**

| | |
|---|---|
| **FT-16** | Closed **end to end, live in production** — `02g` applied, Edge Function redeployed, `ingest_runs` reads `probe_status='stale'`, `stale_days=91` |
| **FT-15 Stream A** (#69) | Schema merged **and applied to prod**. 4 QA rounds, 3 real bypasses. Pass 4 executed the migration against real Postgres. Kevin verified live: `created_at` non-insertable, `source`/`pin_type`/`report_group_id` non-updatable |
| **Phase 0 SPM** (#76) | `supabase-swift 2.55.0`, Auth+Realtime, 7 packages. Purely additive pbxproj. **`Package.resolved` now TRACKED** |
| **Auth Stream A** (#77) | Keychain-backed sessions, auto-resign on `.signedOut`. Compiled clean first try |
| **FT-17** (#72) / **FT-17a** (#74) | Drive Mode free zoom/pan; Recenter reliability. **Kevin validated on-device** |
| **FT-18** (#79) | Bottom Dock redesign + 4 designer-found bugs. **Kevin validated every state on-device** |
| **FT-14/FT-19** (#80) | Geometry regen — see below |
| **FT-15 B1/B4/B3** (#70/#73/#81) | Models, fetch channel + banner, write path + evidence upload |
| **FT-14 follow-ups** (#75) | SAINT↔ST uniqueness gate, proven byte-identical |
| **Mapbox** (#78) | Closed as a **no-op** — "bundle-ID restriction" is not a real Mapbox feature; that false premise is why the item survived ~15 HANDOFF entries |

**THE GEOMETRY WIN (#80) — one root cause, three reported symptoms.** `trimIntersectionSetback()`
shifted `blockGeo`'s coordinate origin with no record of it, so `extractSubSegment()` misread raw
distances. Fixed structurally (`setbackFt` on `blockGeo`; one translation point), plus the
all-or-nothing short-block skip became a continuous clamped taper. **Rows lost 1,624→359 (−78%),
blocks with a dropped zone 3,015→1,842, segments 43,073→44,280, coverage 47%→48%.** It also fixed
**FT-19** (lines overshooting intersections) and **TF2-4** — on `E 2ND ST (2ND→1ST AVE)`, the block
Kevin finally identified, the school zone was rendering **exactly one setback (32.8ft) out of
position**, matching his June wording. QA verified everything independently, including querying live
Socrata itself. ⚠️ **The PR's "zero neighborhood regressions" claim is FALSE** — SoHo 73%→72%, traced
to a reporting artifact from duplicate-vertex growth (12.4%→22.7%), rule composition verified
unchanged. **That duplicate-vertex growth is real and tracked** in `docs/open-items.md`.

**STILL OPEN — #82 (FT-15 Stream B2), the last PR in the project.** Map tap-select + report sheet.
Rebased onto `main` so it finally compiles standalone (it calls B3's symbols). QA 🟡: found that
`blockSelectModeActive`/`driveModeActive` were **not** mutually exclusive despite a comment claiming
so — fixed structurally from both sides. **Needs, in order:** Kevin's compile → a **`PlistBuddy` check
that `NSCameraUsageDescription` reached the built bundle** (W8.5a class of bug; a miss here is a hard
crash on first photo tap, not a degraded feature) → simulator smoke incl. the collision repro.

**🟡 FT-20 — BACKBURNER LIFTED 2026-08-19.** The board cleared, build 16 shipped, Kevin had the
design discussion and settled all six decisions (see `docs/field-testing-log.md` FT-20). Bottom sheet
confirmed as the direction; Drive Mode keeps FT-18's Bottom Dock; search → place → **Go** rather than
auto-entering drive; locate/find-car stay as floating map controls. Dark mode split out and started
first. **⚠️ Process note: the backburner was lifted in conversation but these docs weren't updated
before dispatch — an agent correctly refused to start, citing them. Update the docs BEFORE
dispatching when a standing instruction changes.** Note dark mode is not a one-liner — the red/amber/green polylines are the product's data
encoding and TF2-18 already logged a sunlight-legibility problem. See `docs/field-testing-log.md` FT-20.

**PROCESS LESSONS ADDED THIS STRETCH:**
- **`let` with a default value is EXCLUDED from Swift's synthesized memberwise init.** Broke B4's
  compile; a QA pass had read the same diff and flagged only a style nit. Compilers catch what reads don't.
- **Always `git pull` after `checkout` of an existing local branch** — Kevin smoke-tested stale
  round-1 code once because of this. Use `git checkout -B <branch> origin/<branch>`.
- `xcodebuild test | tail` **misses the summary**; use `xcrun xcresulttool get test-results summary`.
- A transient `FBSOpenApplicationServiceErrorDomain … RequestDenied` launch error mid-run is a stale
  app instance on the simulator; `TEST SUCCEEDED` after it is real — verify via the xcresult count.
- **Do NOT run Homebrew's suggested `sudo rm -rf /Library/Developer/CommandLineTools`** — Kevin's CLT
  are outdated but Xcode 26.4.1 works and we depend on it. Install CLIs from GitHub release binaries.

**NEXT:** #82 compile + PlistBuddy + smoke → merge → **board clear** → cold Release build → archive
build 16 → Kevin's drive test. That build carries FT-17/17a, FT-18, the geometry regen, Keychain auth,
and the complete FT-15 film-shoot-sign feature.


### 2026-08-13 — open-items #16 (Mapbox token restriction) investigated; closed as doc correction, not code work

**WHERE WE ARE:** Kevin approved open-items.md #16 ("Mapbox token restriction — bundle-ID / URL
scoping") for burn-down. Investigation (not implementation) — see `docs/mapbox-token-security.md`
for the full writeup.

**Finding:** the item as worded since W8.5a (2026-05-20) describes a Mapbox dashboard feature
("bundle-ID restriction … via Mapbox's iOS SDK token restriction") that **does not exist.**
Confirmed against current Mapbox docs: URL restrictions are web-only and explicitly incompatible
with native SDKs; the only native-appropriate lever is per-token scope minimization (public vs.
secret scopes). Mapbox has no bundle-ID / application-ID restriction analogous to Google Maps API
keys. This is very likely why the item was re-carried unresolved across ~15 HANDOFF entries over
three months (W8.5a → TF1 ship 2026-06-06 → today) — there was nothing to click.

**What's already adequate (no code change shipped):** the PWA token (`tracker-config.js`) and the
iOS token (`ios/WePark/Config.xcconfig`, gitignored) are separate tokens by design and by evidence
— `docs/drive-mode-scope-spec.md` §4 always said not to reuse the PWA token for iOS, every
post-W8.5a QA pass's `grep -r "pk.eyJ" ios/` hygiene check found zero committed token bytes, and
the W8.5a live smoke (HTTP 200, valid route) is itself evidence the iOS token isn't the
URL-restricted PWA token (a URL-restricted token 403s on requests with no `Referer` header, which
is exactly what native `URLSession` sends — confirmed against Mapbox's troubleshooting docs).

**What Kevin still does, dashboard-only (~5 min, see `docs/mapbox-token-security.md` §3 for exact
steps):** confirm the PWA token's URL restriction survived, label the iOS token distinctly, confirm
its scopes are public-only with no secret scopes checked, and confirm (by comparing prefixes, never
full values) that `Config.xcconfig`'s token isn't accidentally the same value as the PWA token.

**Docs touched:** `docs/mapbox-token-security.md` (new), `docs/drive-mode-scope-spec.md` §4
(correction note, factual error from 2026-05-18 not later regression), `docs/open-items.md` #16.
No `index.html`, `tracker-config.js`, or `ios/` source changes — nothing for `@pwa-maintainer` or
`@ios-engineer` to pick up here.

### 2026-08-13 — burn-down stretch: FT-16 closed live, FT-15 schema APPLIED, SPM landed; build 16 HELD

**WHERE WE ARE:** `main` @ `0457ab43`. Build **1.0 (15) live on TestFlight** and installed on Kevin's
phone but **undriven** — he has no car access until ~2026-08-17. `CURRENT_PROJECT_VERSION` is already
bumped to **16** (`6bbb8514`) but **the archive is HELD**.

**🔑 KEVIN'S STANDING DIRECTIVE (2026-08-13):** *"I don't want to make ANY other proposed changes
until we clear up every single open item."* Stop dribbling builds out. Work everything to *ready*,
then ship **one** build that closes all the on-device verification items at once. The burn-down board
is **`docs/open-items.md`** — keep it current; it marks every item VPS vs Mac.

**🔑 Kevin is the ONLY TestFlight user** (confirmed 2026-08-13). Breaking changes — data migrations,
session resets, state-dropping schema changes — are *cheap right now* and get expensive the moment
the external TestFlight group exists. Don't build migration shims for hypothetical users.

---

**CLOSED THIS STRETCH:**

- **FT-16 — DONE END TO END, LIVE IN PRODUCTION.** Merged #71, Kevin applied `02g` by hand,
  redeployed the Edge Function via the Supabase CLI, and a manual invocation verified the guard:
  `ingest_runs` row 1 reads `probe_status='stale'`, `stale_days=91`,
  `upstream_latest_row_at=2026-05-13`, `error_count=0`. **Before this, that exact run returned zeros
  and looked like a success — which is how a 3-month outage went unnoticed.**
- **FT-15 Stream A schema — MERGED (#69, `a646cf62`) AND APPLIED TO PRODUCTION.** Took **four QA
  rounds**; three found genuine, exploitable bypasses. Pass 4 was the first to **actually execute**
  the migration (the agent installed Postgres locally and ran the real files against real roles/RLS).
  Kevin verified live: 2 new columns, 3 new tables, 2 storage policies, `created_at` **non-insertable**,
  `source`/`pin_type`/`report_group_id` **non-updatable** by anon/authenticated, 3 new constraints.
- **Phase 0 SPM — MERGED (#76, `5e33c141`). The realtime track is unblocked.** `supabase-swift 2.55.0`,
  products **Auth + Realtime only**, 7 packages resolved (6 transitive, all Apple or Point-Free).
  pbxproj diff **purely additive, 38 insertions / 0 deletions**. `xcodebuild clean build` → BUILD
  SUCCEEDED. **`Package.resolved` is now TRACKED** — the old blanket `.gitignore` rule was library
  convention and wrong for an app; untracked resolution is what broke the 2026-06 attempt.
- **FT-17 — MERGED (#72).** Any gesture pauses Drive Mode follow (OQ-4 reversed, spec amended).
- Doc hygiene: **five stale `Status:` lines corrected** in the field-testing log (FT-17, FT-16, TF2-1,
  FT-9, FT-7/8/10 all read "open" while their work had merged, some months prior). Per the log's own
  rule that future sessions trust `Status:` over the header emoji, a stale one is worse than none.

**OPEN PRs (none merged):**

| PR | What | Blocked on |
|---|---|---|
| **#73** | FT-15 Stream B4 — Channel 3 fetch + `TemporaryRestrictionBanner`. Per-channel failure isolation added. | Mac compile. **Schema is now live, so the hard ordering constraint is satisfied.** |
| **#74** | FT-17a — Recenter pill reliability | Kevin's re-smoke |
| **#75** | FT-14 follow-ups — SAINT/ST gate + zone-loss investigation | review |
| _(in flight)_ | Realtime **Stream A** (Auth/Keychain) | agent running |

**FT-17 → FT-17a arc (worth understanding, not just reading):** Kevin reported the map zooming back
in during Drive Mode. Root cause: the Recenter pill *already shipped*, but `followPaused` was set only
by pan, per OQ-4. Kevin's ask reversed that decision → FT-17 (#72). On-device, the pill then appeared
only **sporadically** → FT-17a: `isUserGesture` scanned `mapView.gestureRecognizers`, which contains
only **our own tap and long-press** — MapKit's pan/pinch live on internal subviews. Fixed with
dedicated passive observer recognizers. Kevin's round-2 smoke then found **two more**: Recenter didn't
move the map (it waited for the next GPS tick — invisible on a static simulator location), and
pan/pinch felt **worse**. That second one was caused by making detection reliable: `onDrivePanDetected`
began firing on *every* `regionWillChangeAnimated` during a gesture, each one writing SwiftUI `@State`
→ per-frame re-renders. Both fixed in round 2; **awaiting re-smoke.**

**FT-18 (NEW) — Drive Mode layout redesign, `docs/design/ft18-drive-mode-layout.md`.** The designer
read the code rather than the screenshot and **found four bugs nobody had filed**: (1) the top row ends
in a trailing `Spacer()` that crushes three buttons left while a separate toolbar floats right — the
actual cause of the "two anchors" look; (2) the gear button and End Drive pill render at *identical*
coordinates; (3) the mute toggle renders **twice** in Cruise Mode; (4) "Find me"/"Find my car" stay
live during Drive Mode but call the browse-mode camera path, producing a broken camera state mid-drive.
It also **pushed back on Kevin's "all buttons on the bottom"** for the destructive End control, citing
Apple Maps' own isolation of that control. **⏳ 5 open questions awaiting Kevin — this blocks both the
redesign and the four bug fixes, since they're the same code.**

**FT-14 follow-ups (#75):** SAINT↔ST uniqueness gate added — the investigation doc's claim of "3
Saint-prefixed streets" was wrong, there are **37** — and proven a **pure no-op today** (live pull
through gated vs ungated pipelines produced **byte-identical** tiles: 1,070/1,070, 42,975/42,975
segments). **No regen needed.** Separately, the 1,528-row **zone-construction loss is root-caused but
deliberately NOT fixed**: `createSubSegments()` builds zone boundaries in raw intersection-relative
distance while `extractSubSegment()` interprets them *after* `trimIntersectionSetback()` shifted the
origin by the 10m setback; zones past the trimmed length collapse and take their rules with them.
Reproduced exactly (raw 256.56ft → trimmed 190.94ft = 256.56 − 2×32.8). **Affects ~28% of
geometry-successful blocks (3,008/10,613).** The fix changes rendered geometry and needs its own regen
— **Kevin's call, its own dedicated pass.** Plausibly a real chunk of the coverage still missing.

**PROCESS LESSONS (hard-won this stretch):**
- **This VPS has 2 CPU cores.** Concurrent agents *contend* rather than parallelize — with 4-5 in
  flight, throughput varied ~30x (123 tool calls in 23 min vs 23 tool calls in 2.2 h). **Keep it to
  1-2 agents.** Fan-out here costs wall-clock and legibility for no gain.
- **File contention, not agent capacity, is the real bottleneck.** `MapViewRepresentable.swift`,
  `ContentView.swift`, and `CommunityPinService.swift` are each wanted by 2-3 streams. Serialize.
- **`FETCH_HEAD` is a single mutable ref shared across concurrent agents in one working tree.** A QA
  pass silently reviewed the wrong branch's diff before catching it. Pin the SHA to a local ref.
- `gh pr view`/`gh pr edit` fail on this repo (projects-classic deprecation) — use `--json`; body edits
  via `gh api repos/kevhox1/parkmap/pulls/<n> -X PATCH`. `gh pr diff <n> -- <path>` rejects a path arg.
- `xcodebuild test | tail -N` **misses the summary** under parallel clone testing. Use
  `xcrun xcresulttool get test-results summary --path <bundle>` whenever a count gates something.
- Homebrew on Kevin's Mac fails on outdated Command Line Tools. **Do NOT run its suggested
  `sudo rm -rf /Library/Developer/CommandLineTools`** — Xcode 26.4.1 works and we depend on it.
  Install CLIs from GitHub release binaries instead (that's how the `supabase` CLI got there).
- **Security fixes that depend on client-controlled columns keep failing.** Three of #69's four rounds
  found a bypass of that exact shape. The fix that worked was structural — take the columns away via
  `REVOKE` table-level then `GRANT` column-level. Note a bare column-level `REVOKE` is a **silent
  no-op** against a table-level grant (verified empirically).

**NEXT:** Kevin's re-smoke of #74 → merge → B2 unblocked · Kevin's 5 FT-18 answers → redesign + 4 bug
fixes · Kevin's TF2-4 cross streets · Stream A lands → Stream B after FT-15 settles · #73 Mac compile
→ merge · B3 · Mapbox token · then **one** build 16 archive, then the drive test (~2026-08-17).

### 2026-08-11 — #68 merged + build 15 bumped; FT-15/FT-16 opened; three PRs in flight

**WHERE WE ARE:** `main` @ `5f74219`+. **PR #68 MERGED** (`b5da617`) on Kevin's explicit call
*without* a completed independent QA pass — he had stopped the earlier QA agent mid-run. That caveat
is recorded in the FT-14 log entry rather than left to disappear. **`CURRENT_PROJECT_VERSION` bumped
14→15** (`b3237d45`, all 4 pbxproj slots; `MARKETING_VERSION` stays 1.0). **The build 15 archive is
HELD** pending `docs/qa/ft14-normalizer-regen7-qa.md` — Kevin's decision: QA gates the archive, it
does not merely inform it. Kevin moved to the Mac late in the session; test/compile commands issued,
results pending.

**Kevin's standing rulings this session (do not re-open):**
- **He applies Supabase migrations to production HIMSELF, by hand.** No agent applies schema to prod,
  ever. Engineering writes the migration; QA clears it; Kevin runs it.
- **OQ-1 → MARKER.** FT-15 phase 1 renders via the existing `PinMarkerAnnotation`; the dashed/hatched
  polyline treatment is deferred to a follow-up. (The multi-segment *selection* highlight during
  tap-select is still new `MapViewRepresentable` surface — the live-UI smoke gate still stands.)
- **Mac boundary protocol:** drive every VPS-runnable stream to the Swift-toolchain/simulator edge,
  then say plainly that a Mac is required and what for. Never fake or assume a compile/test result.

**FT-15 (NEW, large) — temporary block restrictions from posted paper signs.** Kevin photographed an
NYPD "NO PARKING — FILM SHOOT" placard covering **E 2nd St, 3rd Ave→1st Ave = 2 blocks × 2 curbs =
4 blockfaces**. Spec written covering **FT-15 + TF2-15 (construction) as ONE shared primitive**:
`docs/ft15-tf215-temporary-block-restrictions-spec.md`. Core design — extent is picked by **map
tap-select**, with block identity read verbatim off the tapped tile segment via a new
`Segment.blockfaceKey`, deliberately so the FT-14 naming problem is never re-solved on-device.
Sizing is honest: **backend 1 session, iOS 4–6** — not a quick add-on to `ReportSheet`.

**FT-16 (NEW) — the `filming` layer has been silently empty for ~3 months.** Our
`ingest-film-permits` cron pulls `tg4x-b46p` and filters to current/future permits; that dataset
froze ~2026-05-12 (hard cliff to zero submissions from June, not a decline). No error was ever
raised — same failure SHAPE as TF2-19. An "intentional publishing embargo" theory was tested and
killed by measuring real submission-to-start lead times (1–5 days, not months). No replacement feed
exists (`tvpp-9vvx` rejected: wrong agency, wrong content). **Consequence: for filming, the FT-15
crowd path is currently the ONLY signal** — open-data corroboration must stay strictly optional.

**Three PRs open, NONE merged:**
| PR | What | State |
|---|---|---|
| **#69** | FT-15 Stream A schema, `supabase/02f-block-scoped-restrictions.sql` | QA said **DO NOT APPLY**; both blocking findings fixed; **needs re-QA** |
| **#70** | FT-15 Stream B1 iOS models (`Segment.blockfaceKey`, `CommunityPin` fields) | QA 🟡 ship-with-caveats; fixes landed; **COMPILE-UNVERIFIED, needs Mac** |
| **#71** | FT-16 staleness guard + `supabase/02g-ingest-runs.sql` | QA running |

**Two real defects independent QA caught (the case for the builder≠verifier rule):**
1. **Abuse-control bypass (#69).** Both the hard-ceiling CHECK and the rate-limit trigger keyed off
   `report_group_id is not null` — a client-supplied, RLS-unenforced column. Omitting it exempted an
   insert from both, and Channel 3's fetch predicate has no `report_group_id` filter, so the row
   still rendered as a live closure. Fixed with a `NOT VALID` correlation constraint (right call —
   no prod access to verify existing rows, and `NOT VALID` cannot abort Kevin's `ALTER TABLE`).
2. **`pins_with_author` is `select p.*`** (`02-pins-schema.sql:274`) — PostgreSQL expands `*` at
   view-creation time, so the migration's new columns would never reach any client and the whole
   feature would silently do nothing. Fixed by an explicit column list. **Trap avoided:** a naive
   `create or replace ... select p.*` FAILS (can only append, not reorder — `p.*` would put the new
   columns ahead of `author_username`), and the `DROP VIEW` route silently loses
   `grant select to anon, authenticated`. Column list hand-verified: 19 original columns in original
   order, 2 appended.

**Also caught: migration-ordinal collision.** #69 and #71 both created a `supabase/02f-*.sql` —
not a git conflict, so it would have merged cleanly and left two ambiguously-ordered `02f`
migrations in the directory Kevin applies **by hand, in filename order**. #71 renamed to `02g`.

**Process notes worth keeping:**
- `gh pr view`/`gh pr edit` fail on this repo (projects-classic GraphQL deprecation). Use
  `gh pr view --json ...`; for body edits use `gh api -X PATCH`. Also `gh pr diff <n> -- <path>`
  rejects a path arg on this gh version.
- **`FETCH_HEAD` is a single mutable ref shared across concurrent agents in one working tree.** A QA
  pass here silently reviewed the wrong branch's diff before catching it. Pin the SHA to a local ref.
- iOS code written on the VPS is **compile-unverified** — label it so in PR bodies, and get
  `project.pbxproj` references right (the project uses `PBXFileSystemSynchronizedRootGroup`, so files
  under a synchronized root need no explicit entry).

**🚀 BUILD 1.0 (15) SHIPPED TO TESTFLIGHT 2026-08-11 — archived, uploaded, installed on Kevin's
phone.** Payload: regen 7 tiles (#68) + FT-13 "?" toolbar button (#67). Kevin's on-device pass is
now the gate; see the FT-13 / FT-14 / TF2-16..19 entries in `docs/field-testing-log.md` for what's
outstanding. **⏳ Awaiting Kevin's drive-test.**

**BUILD 15 MAC VERIFICATION — PASSED (2026-08-11, Kevin's Mac, Xcode 26.4.1):**
- Cold `xcodebuild clean build -configuration Release` on `main` @ `4566dea9` → **`** BUILD SUCCEEDED **`**
- Full suite on iPhone Air sim (iOS 26.4.1) → **585 passed / 0 failed / 0 skipped, `result: Passed`**
  (`xcrun xcresulttool get test-results summary` — the authoritative read; a `| tail -30` on the raw
  `xcodebuild test` output MISSES the summary under parallel clone testing, because the final
  `** TEST SUCCEEDED **` flushes before the last clone's trailing per-test lines. Use the xcresult
  bundle, not a tail, whenever a pass/fail count actually gates something.)
- Note: the older "377/0" baseline elsewhere in this file is stale — the suite has grown to 585.
**REGEN-7 QA — ✅ SAFE TO ARCHIVE** (`docs/qa/ft14-normalizer-regen7-qa.md`, 2026-08-11). Every
quantitative claim in #68 re-derived from scratch and matched **exactly**: coverage 43%→47%, Harlem
38%→64%, SoHo 65%→73%, Village 70%→73%; all 5 category counts; corridors (St Nicholas 444,
Lenox/Malcolm X 192); Kevin's origin block recovered both sides; all 8 aliases verified against real
OSM keys; 39-added/1-removed tile counts identical between `tiles/` and the iOS mirror. On the lost
completeness-gate log line, it built four independent consistency checks (Socrata count growth,
segment-count tracking, flat rules-per-segment ratio, uniform proportional category growth) that all
indicate a complete pull, **not** a TF2-19-style truncation → no fresh regen needed before archive.

**🟡 FT-14 FOLLOW-UP (not blocking build 15) — SAINT↔ST has no uniqueness gate.** The investigation
doc justifies the SAINT↔ST swap by claiming OSM has exactly **3** Saint-prefixed streets citywide.
That is **factually wrong — there are 37.** QA adversarially re-checked all 37 against regen-7 output
and the single abbreviated `St `-prefixed OSM key and confirmed **zero wrong-street collisions
today**, so no current bug. But unlike its sibling compact-spacing fallback, this path has **no
uniqueness check** — it's a defense-in-depth gap that a future OSM data refresh could turn into
silent wrong-street sign attachment, the worst failure mode this pipeline has. `@backend-data`:
correct the doc's count and add a collision gate, normal cadence.

**Process improvement flagged by QA:** capture the fetch completeness-gate expected/fetched numbers
to a durable log during regen — losing them to an interrupted session is what made this verification
harder than it needed to be.

**⚠️ CHORE — DO IMMEDIATELY AFTER PR #71 MERGES (do not lose this):** the **FT-16a** deferred-alerting
block in `docs/field-testing-log.md` still says **`ingest_runs.stale`**. That column was renamed to
**`ingest_runs.probe_status`** (tri-state `fresh`/`stale`/`probe_failed`) by #71's round-2 QA fix. The
block was deliberately left untouched during #71's rebase so the deferral text couldn't be watered
down, and it is NOT being fixed on `main` before the merge because that would re-conflict #71 for a
one-word change. **Swap the term the moment #71 lands** — a deferred-work note that names a column
which no longer exists is exactly the kind of rot that misleads the session which eventually picks
FT-16a up.

**NEXT:** #70's compile on the Mac → regen-7 QA verdict → archive or fix → re-QA #69 → Kevin applies
`02f`/`02g` by hand → FT-15 B2/B3/B4 (B2 is Mac-shaped).

### 2026-08-10 — FT-14 coverage recovery: PR #68 OPEN awaiting QA decision; build 15 queued behind it

**WHERE WE ARE:** main clean @ `071a3e0`. Build **1.0 (14) live on TestFlight** and correct (see prior
entry). **THE ONE OPEN DECISION: PR #68** (`data/ft14-normalizer-regen7`) is open, unmerged —
Kevin manually stopped the QA agent mid-pass and hasn't yet said whether to (a) restart the
independent QA pass (~15 min, recommended — orchestrator was the builder-of-record on this PR and
must not self-certify) or (b) merge without it this once. **Resolve that first.**

**FT-14 arc (this stretch's work):** Kevin found uncovered streets driving Bleecker @ LaGuardia Pl →
built `scripts/coverage-report.js` (per-neighborhood coverage vs CSCL centerlines; run after every
regen) → found Manhattan at 43% coverage → root cause: **11% of sign rows (6,044/54,987) silently
dropped at the street-name join** (NYC spells "LA GUARDIA PLACE" multiple ways; SAINT↔ST; alias
co-names like Lenox/Malcolm X) → investigation `docs/qa/ft14-join-drop-investigation.md` → Kevin
approved fix + regen 7 → PR #68: 3-part normalizer fix (confined to `osmName()`/`NYC_TO_OSM`) +
regen 7. **Orchestrator-verified pre-PR:** coverage 43%→47% (Harlem 38%→64%, +39 new upper-Manhattan
tiles), Bleecker LA GUARDIA PLACE→MERCER recovered BOTH sides, zero category regressions (all +4-11%,
ASP +17% = same-join recovery), tiles ≡ iOS Resources, sw.js v38→v39. The stopped QA agent had
independently confirmed the spacing recoveries (24 new Bleecker faces) before being killed.
**Process note:** the implementing agent was interrupted twice by session restarts; orchestrator
finished verification+commit+PR directly (removed the builder's leftover env-gated TEMP block
before committing). Builder worktree still exists at `.claude/worktrees/agent-a2320b83663818029`
(holds branch `data/ft14-normalizer-regen7` — `git worktree remove` it before merge, else the
branch delete fails; same gotcha hit on #63/#65).

**After #68 merges → cut BUILD 15:** bump `CURRENT_PROJECT_VERSION` 14→15 (both configs, 4 slots),
full suite + cold Release compile (headless CodeSign failure = expected env artifact, compile is
the signal), commit, then Kevin's archive protocol (**⌘Q Xcode first** — stale-build-number gotcha,
builds 8/12 — reopen, verify 15, Archive → Distribute → Upload). Build 15 payload: regen 7 tiles +
FT-13 `?` toolbar button (#67, merged post-14, verified but never shipped).

**KEVIN'S OUTSTANDING ON-DEVICE GATES (do on a WEEKDAY or Saturday, build 14 or 15):**
TF2-16 heading locks at intersection approaches, no spin, releases through turns; TF2-17/18 chips
read "Free until X" + sunlight-legible; TF2-19 Bowery/Houston metered/no-standing in-window
(remember TF2-20: Sunday green is CORRECT); Parking 101 — Settings row tap-through, large Dynamic
Type plates, fresh-install banner; build 15 adds: `?` toolbar button, Bleecker @ LaGuardia now
colored, Harlem coverage jump.

**BACKLOG (unchanged order):** supabase-swift real-time (hard TF2 req), external TestFlight group
(privacy URL ready), Mapbox token bundle-ID restriction, FT-2 delete-own-pin (spec'd), TF2-15
construction layer, tech-debt batch, FT-14 follow-ups explicitly deferred from #68 (1,528-row
zone-construction loss; ~800 dead-end/ramp rows unfixable by renaming; the big "NYC posts no signs
on many blocks" gap ≈ remaining ~50 pts), PWA `APP_VERSION` label drift (cosmetic, pwa-maintainer).
Also: `docs/resume-bullets.md` exists (Kevin's resume source material — keep numbers current if he
asks again).

**PROCESS REMINDERS:** field-testing-log Status: lines = truth; spec-first; QA ≠ builder before
every merge; isolated worktrees for git-touching agents; ONE simctl-created simulator per
concurrent agent; live-UI smoke for ContentView/mount-chain PRs; Kevin's real-device drive = the
gate for all camera/GPS behavior; QA agents must WRITE reports to docs/qa/ (several returned text
without writing); unpair the passcode-locked iPhone from this Mac (slows every test run).

### 2026-07-13 — Build 14 SHIPPED to TestFlight; regen 6 (the real data fix); TF2-16..20 + FT-12/13; drive-test pending

**WHERE WE ARE:** main clean @ `ac82021`, **build 1.0 (14) uploaded to TestFlight and on Kevin's phone**
(archive hit a PLA-agreement + distribution-cert error first — fixed by accepting the updated Program
License Agreement at developer.apple.com; the cert auto-created after). ~585 iOS tests. PWA cache v38
(incidental — Kevin is iOS-only focused; don't lead with PWA).

**The headline: TF2-19.** Kevin's build-13 report "Bowery shows free but it's metered/no-standing" →
investigation found **regen 5 had silently shipped an incomplete Socrata pull** (~40-48% of ALL non-ASP
rules missing citywide; ASP unaffected — separate fetch). Fix (#63): hardened `fetchSocrataDataset()`
(`$order=:id` stable pagination, retry+backoff, fail-CLOSED count(*) completeness gate that aborts the
build before any tile write) + **regen 6**, QA'd to SHIP CLEAN with independent byte-level recount.
Regen 6 is plausibly the first genuinely complete pull ever (old fetch had no `$order` → every prior
regen likely dropped rows). Build 13 should NOT be distributed (defective tiles).

**Also in build 14:** TF2-16 heading snap-to-street (#64 — one-way bearing at low course confidence,
hysteresis, zero MapViewRepresentable diff); TF2-17 "Free until X" chips + TF2-18 drive design pass
(#66 — solid chips, WCAG-passing contrast both modes, orange `.comingSoon` tier restored, Recenter/End
Drive clearances, palette doc §8); FT-12 Parking 101 guide (#65 — Views/ParkingGuide/, sign replicas,
one-shot launch banner, docs/parking-101-content.md; QA caught + fixed a spec-inherited No-Parking-vs-
No-Standing teaching error). Post-14 on main: FT-13 `?` toolbar button (#67) — rides the next build.

**TF2-20 (the great Sunday scare): NOT A BUG.** Kevin saw Bowery all-green at 5pm Jul 12 on build 14 →
Jul 12 is a SUNDAY; Bowery signs are "EXCEPT SUNDAY" → green correct. Real-engine-on-real-bundle
harness: Sun 5pm = 85 green (matches observation), Sat 5pm = 67 red/22 amber. Regen 6 verified
effective end-to-end. **Process lesson: check the calendar before diagnosing schedule-dependent
behavior.**

**OPEN / NEXT:**
- **Kevin's drive-test gates (build 14, on a WEEKDAY/Saturday):** heading locks at intersection
  approaches (TF2-16); chips "Free until X" + sunlight legibility (TF2-17/18); Bowery/Houston read
  metered/no-standing in-window (TF2-19); Parking 101 taps — Settings row, `?` button (next build),
  large Dynamic Type plates, fresh-install banner.
- Then the standing backlog: supabase-swift real-time (hard TF2 req), external TestFlight group,
  Mapbox token restriction, FT-2 delete-own-pin (spec'd), TF2-15 construction layer, tech-debt batch
  (now incl. TF2-16 doc-comment nit + sim-only cold-launch polyline note).
- **Infra:** unpair the passcode-locked physical iPhone from this Mac (Xcode diagnostics collector
  times out against it, inflating every local test run).

**PROCESS NOTES:** concurrent agents each get their own simctl-created simulator (shared-sim collisions
bit us); QA reports must be WRITTEN to docs/qa/ by the agent (two returned text without writing);
ContentView @State-block merge conflicts between parallel iOS PRs are the known cheap kind (keep-both);
one agent misread harness system-reminders in a tool result as prompt injection (benign, investigated).

### 2026-06-15 — TF2 field-testing marathon: builds 1.0(2) → 1.0(13), native-MapKit MAP REBUILD, 5 tile regens

**WHERE WE ARE:** main clean @ `b6307d4`, **build 1.0 (13)** cold-built and PUSHED, **ready for Kevin to archive**
(not yet uploaded). ~514 iOS tests. PWA live at cache v37. This was a long hands-on TestFlight field-testing
loop; **`docs/field-testing-log.md` is the running record** (NOTE: trust the `**Status:**` line inside each
entry — the header 🔴/🟡 emojis are stale; most are actually 🟢 shipped).

**Immediate next action (Kevin):** ⚠️ **QUIT XCODE FIRST** (⌘Q — recurring gotcha: Xcode caches project.pbxproj
and archives a stale build number; happened on builds 8 & 12), reopen, verify `= 13`, then Product → Archive →
Distribute → Upload **1.0 (13)**. Then **drive-test** the two headline fixes below.

**Build 13 headline fixes (Kevin's on-device gate — sim can't move GPS):**
- **Zoom saga FINALLY fixed (TF2-11 Option A, PR #62):** after 4 failed patch rounds, we DROPPED MapKit's
  `.follow` in Drive Mode entirely and drive the camera ourselves — one animated `setCamera` per GPS tick
  (center+pitch30+our altitude; heading owned by the course-EMA `syncDriveHeading` path). Nothing fights the
  camera now. Deleted all prior machinery (zoom clamp, TF2-8 re-apply, tracking-mode plumbing). Gate: enter
  Find Parking/destination WHILE MOVING → camera follows smooth + STAYS tight (no bounce), heading-up, Recenter
  on pan, pinch-zoom persists.
- **Curb widths (TF2-14 regen 5):** parking lines now use NYC CSCL `streetwidth` data, computed ONCE PER STREET
  (uniform → no zigzag). Houston/Bowery ~12.7m offset (parking lane, was 10m mid-road), avenues 10m (no
  regression), side streets 6m. Gate: Houston/Bowery read on-curb + consistent. Tuning knob if still not far
  enough: `DIVIDED_MEDIAN_ALLOWANCE_M` in build/preprocess.js (one constant).

**The big arc shipped this stretch (all merged, in build ≤13):**
- **MAP REBUILD → native MapKit** (docs/map-rebuild-native-mapkit-spec.md): Phase 1 browse liberation
  (rotate/tilt, MapKit owns browse camera — VERIFIED on-device "just like Apple Maps"), Phase 2 native drive
  follow (later replaced by Option A above). This killed the whole snap-back/fighting-the-camera class.
- **FT-1..FT-11 + TF2-1..TF2-14** — see field-testing-log. Highlights: FT-5 pan snap-back, FT-6 customizable
  reminders (15m/30m/1h/2h/night-before), FT-7 course-heading, FT-9 **metered-shown-as-free citywide fix**,
  FT-11 sweeper/agent direction picker + marker chevron (+ oneway tile fields), TF2-3 heading-up puck,
  TF2-6 cruise camera, TF2-7 side-level voice + "Park here" sign-check sheet, TF2-9 sheet layout, TF2-10/12
  perpendicular curb offset + block-normal fix + stub filter, TF2-13 Elizabeth garage zone-cap (~614 faces).
- **Privacy policy PUBLISHED** at https://kevhox1.github.io/parkmap/privacy.html (unblocks external TestFlight).

**OPEN / NEXT (nothing in flight — clean board):**
- **FT-2 delete-own-pin** — SPEC'D (docs/ft2-delete-own-pin-spec.md), NOT built. RLS likely already in schema
  (verify), then iOS delete UI on own pins. Good next feature.
- **TF2-15 (roadmap):** construction/temporary-conditions layer (NYC permit data → `construction` pins) — Bowery
  is metered-but-under-construction; static sign tiles can't know that.
- **Concept docs for later:** docs/smart-parking-route-2.0-concept.md (parking-hunt route optimizer, 2.0),
  docs/nyc-neighbors-incentives-concept.md (community rewards / brand partnerships).
- **Tech-debt cleanup batch** (field-testing-log top): Swift concurrency warnings, FT-7 selectDriveHeadingSource
  wiring, FT-9 string-match→boolean, Option A doc nits.
- **Still pending from before:** supabase-swift SDK (real-time, hard TF2 req), external TestFlight group setup
  (privacy URL now ready), Mapbox token bundle-ID restriction, Tier 2 (sign corrections/reputation).

**PROCESS THAT WORKED (keep doing):** field-testing-log = source of truth; spec-first for anything non-trivial
(tech-lead); QA-verifier ≠ builder before every merge/build; isolated worktrees for git-touching engineers;
cold `xcodebuild clean build -configuration Release` before each archive; tile regen = `node build/preprocess.js`
(runs on Kevin's machine, fetches NYC Socrata, ~5-15min, writes tiles/ + ios Resources/tiles/ — bump sw.js
CACHE_VERSION for PWA); measure tile output before committing a regen; decouple tile regens from iOS-code builds
when one is blocked. Kevin drive-tests on real device = the irreducible gate for all camera/GPS behavior.

### 2026-06-06 (🚀 TF1 SHIPPED) — WePark 1.0(1) is LIVE on TestFlight

**The Phase 5 goal is achieved: a real signed build is on TestFlight and installs on Kevin's iPhone.** The full archive → upload happened via Xcode GUI (orchestrator guided Kevin step-by-step, Supabase-style). Key facts for the future:
- **Apple Developer:** Kevin Hoxha, **Individual**, **Team ID `ZAA4UCS6CH`**, paid through 2027 (Apple ID `kevinhx2010@gmail.com`).
- **Bundle ID CHANGED:** `com.wepark.app` was taken globally → registered + switched to **`com.kevinhoxha.wepark`** (PRODUCT_BUNDLE_IDENTIFIER updated for the app target both configs, `9afe0f7`; test target still `com.wepark.app.tests` — harmless, non-blocking). Xcode wrote `DEVELOPMENT_TEAM = ZAA4UCS6CH` + automatic signing.
- **App Store Connect app:** display name **"WePark-NYC"** ("WePark" was taken), app id 6777589379, bundle `com.kevinhoxha.wepark`.
- **Archive hurdle solved:** automatic signing failed with "Communication with Apple failed / team has no devices" — the fix was **registering a device** (Kevin's iPhone 15 Pro, UDID `00008130-0012444010A1401C`). After that, Product→Archive succeeded; Distribute→App Store Connect uploaded clean (Xcode 26 auto-defaults the option screens). Export compliance auto-cleared (the `ITSAppUsesNonExemptEncryption=NO` flag worked — build went straight to **"Ready to Submit"**, no compliance prompt).
- **Build status:** 1.0 (1), Ready to Submit, internal testing group created, Kevin added himself + enabled auto-distribute. Installing via TestFlight app on his phone.

**Open TF-follow items (next session):**
- **External beta** (friends / NYC drivers / wider): needs an EXTERNAL group + "Test Information" filled (beta description, feedback email, privacy URL) + a one-time **Beta App Review** (~1 day). Orchestrator offered to help set this up (~15 min form).
- **Mapbox token bundle-ID restriction** — STILL NOT DONE (Kevin's task; restrict the public token to `com.kevinhoxha.wepark` on the Mapbox dashboard — note the NEW bundle id).
- **Host the privacy policy** (`docs/privacy-policy.md`) at a public URL (GitHub Pages) + fill contact email + paste into App Store Connect → App Privacy (required before external/public).
- **🔴 supabase-swift SDK = hard TF2 req** (real-time websockets — see the SDK note below; poll is the 8s stand-in).
- **Real-device feedback** — Kevin now has it on his phone; first real-device pass of Drive Mode / Find Parking / reporting will surface calibration (voice cadence/gaps, font sizes, the W8.5c-follow items) that the sim couldn't. This effectively replaces the long-pending "drive-test" gate.
- Captcha on anon sign-ins (pre-public). Delete 2 forever-test pins (`delete from public.pins where source='crowd' and expires_at > '2030-01-01'`).

### 2026-06-06 (TF1 prep) — icon, config, privacy, FAQ, banner-color, real-time band-aid

**Polish + TF1-readiness pass.** Shipped: **amber ASP banner** (PR #44 — fixed backwards color semantics: suspended=green/good, in-effect=amber/caution; matches the map's green=good language), **Help & FAQ screen** (PR #45 — beginner NYC-parking guide + how-to + official NYC.gov links, content in `docs/in-app-faq-content.md`, reachable from Settings), **real-time band-aid** (PR #43 — pin poll 25s→8s; full websocket SDK is a HARD TF2 requirement), **app icon** (white map-pin + green "P"/"NYC" on green gradient — generated via Swift/AppKit since no Pillow/ImageMagick; `sips` to resize to 1024), **TF1 build config** (PR #46 — corrected the location usage string [it falsely claimed "never sent off device"; community reports DO send a chosen location] + added `ITSAppUsesNonExemptEncryption=NO` to skip the export-compliance prompt), and a **privacy policy draft** + App-Store-Connect privacy-label answers (`docs/privacy-policy.md`).

**⚠️ Cold-build lesson:** `FAQHelpView` (PR #45) merged with a latent type error (`faqSection(content:)` got a value, not the expected `() -> some View` closure) that passed WARM incremental builds but **failed a cold/clean build** — exactly what a TF1 archive is. Caught only when the icon build forced a fresh compile. Fixed (`33e994b`, wrap in `{ }`). **LESSON: use `xcodebuild clean build` (not warm incremental) for any TF1-archive-critical verification** — warm derivedData masks cold-build failures. (Tests now 377/0, clean build verified.)

**TF1 status — code is ready; gap is Apple-account mechanics (Kevin's):**
- ✅ DONE (orchestrator): app icon, privacy string accuracy, export-compliance flag, privacy-policy draft, FAQ, amber banner, cold-build verified.
- ⏳ KEVIN: (1) Mapbox token bundle-ID restriction (`com.wepark.app`); (2) App Store Connect app record; (3) Signing & Capabilities (Developer Team + distribution signing — `DEVELOPMENT_TEAM` is currently unset); (4) host `docs/privacy-policy.md` at a public URL (e.g. GitHub Pages) + fill the contact email + paste URL into App Privacy; (5) then archive (Release) + upload to TestFlight. Tier 3 IS in TF1 (Kevin's call).
- Cleanup: delete the 2 forever-test pins (`delete from public.pins where source='crowd' and expires_at > '2030-01-01'`).

### 2026-06-06 (later) — Tier 3 goes LIVE in prod + 5 live-test bugs fixed (Kevin's hands-on session)

**Milestone: the community reporting loop works end-to-end in production.** Kevin enabled the two backend prereqs — **Anonymous Sign-ins** (Supabase → Auth → Anonymous; was OFF by default — this was the #1 "submit fails" cause, diagnosed via a direct `curl /auth/v1/signup` returning `anonymous_provider_disabled`) and applied **`02e-auto-resolve-trigger.sql`**. Verified via prod curl: anon sign-in → 200, insert crowd pin → 201 (RLS accepts). Then Kevin live-tested on the sim and found 5 real bugs, all fixed across **PR #41 + #42**:

**PR #41** (`eb2d5e0`) — 3 bugs: (1) **crowd pins never displayed** — the fetch only pulled `source=eq.open_data` Tier 1 pins; added a 2nd concurrent fetch channel for `source=crowd` ephemeral enforcement/sweeper pins; (2) **long-press opened the parking-info card instead of the report dialog** — added `tap.require(toFail: longPress)` in MapViewRepresentable so a hold always wins over the segment tap (quick tap still opens block detail; ~0.4s tap delay is the accepted tradeoff); (3) **in-drive Report gave no block context** — ReportSheet now shows "Reporting on <street>" via `drivingContext?.street`. QA: orchestrator-verified PASS (`docs/qa/tier3-pr41-qa.md`; the qa-verifier agent flaked on the blank-sim artifact, so the orchestrator — not the author — independently ran tests + reviewed the #31-class gesture diff).

**PR #42** (`e9d0bea`) — 2 bugs (slow/missing pins): root cause = NO instant feedback + NO auto-refresh (fetch only fired on map pan; `insertCrowdPin` used `return=minimal`; `startRealtime()` is a stub). Fixes: (1) **instant feedback** — `insertCrowdPin` now `return=representation` + appends via `mergeRealtimeChange` so a report appears immediately; (2) **periodic refresh** — a ~20–30s repeating re-fetch of the visible region (interim until websocket Realtime) so pins appear/expire without panning; (3) **marker safety net** — `markerImage` falls back to a colored dot if an SF Symbol fails to resolve (a pin must never silently vanish). NOTE: the "sweeper didn't appear" was NOT an icon bug (`truck.box.fill` resolves) — it was the refresh gap (sweeper was reported after the last pan). **Tests 351 → 373/0.** QA: orchestrator **live-verified** — inserted fresh enforcement+sweeper pins via the live anon-auth path and screenshotted BOTH a teal `person.badge.clock.fill` and a cyan `truck.box.fill` marker rendering at SoHo WITHOUT panning (`docs/qa/tier3-pr42-qa.md`). Tier 3 reporting is now confirmed working live, end to end.

**OUTSTANDING:**
- **🔴 SDK = HARD TF2 REQUIREMENT (not optional):** adopt `supabase-swift` → real websocket Realtime (others' reports push in ~1-3s) + Keychain session storage. **Kevin's call (2026-06-06): this is a must-have for the true final product — "time is crucial when it comes to parking"** (a 25s/8s lag on "enforcement on your block NOW" can mean the difference between moving your car and a ticket). Deferred from TF1 only because (a) real-time has no value until user *density* exists, and (b) the SPM-without-Xcode add is fiddly (bit us once — solve via careful pbxproj edit + `xcodebuild -resolvePackageDependencies`, or one reviewed Xcode package-add). **Interim shipped:** poll interval dropped 25s → **8s** (PR #43, `e06cd8f`) so beta/demo feels reasonably live. NOTE: periodic refresh is currently SUSPENDED during active Drive Mode (battery) — the SDK websocket push should REPLACE that so community pins stay live even while driving/Find-Parking (you most want fresh enforcement pins while circling). Estimate for the full SDK fix: ~few hours + some SPM detour risk.
- **Pre-launch hardening:** enable **captcha** on anonymous sign-ins (Supabase warned: prevents bot sign-up spam / MAU bloat) before public launch.
- **Cleanup:** 2 test crowd pins were inserted with a 2099 expiry for the render smoke and will NOT auto-expire — delete them (`delete from public.pins where source='crowd' and expires_at > '2030-01-01'`).
- Same-coord reported pins overlap (no clustering yet) — minor, future.

### 2026-06-06 — Tier 3 sub-PR #2 ships: universal community reporting (no patrol mode)

**Product pivot (Kevin):** DROPPED the separate "Patrol mode." Reporting is now UNIVERSAL — the destination-less "look for parking" experience stays as the shipped **Find Parking / Cruise Mode**, and reporting is a capability available everywhere, not a mode you enter. Two context-appropriate affordances: (1) **resting/browsing** → long-press a block → `confirmationDialog` ("Park my car here" [W5, intact] / "Report enforcement or sweeper"); (2) **driving** (destination OR Find Parking) → one-tap **Report** button in the drive overlay (`flag.fill` + "Report" label, orange, inline with End pill + mute) → `ReportSheet` → drops the pin at current GPS (Waze-style, driving-safe — long-press is a no-op while driving). The `DriveModeStyle.patrol` enum case was removed.

**What landed:** **PR #40** (`7da7eca`). New `Views/ReportSheet.swift` (Enforcement active [+ optional sub_tag pill: cleaning-truck-first / parking-agent / tow-truck / "not sure"=nil] / Street sweeper [passed / approaching]; neutral compliance copy, no "ticket"/"avoid" language; calls the sub-PR #1 `insertCrowdPin` with lifespan='ephemeral', source='crowd', expires_at=now+30min). `timeSinceBadge(pin:now:)` pure function (T3-3 decay = time-since badge). Marker icons per `@designer` (`docs/design/tier3-marker-icons.md`): **enforcement = `person.badge.clock.fill` teal** (civic/neutral, NOT a shield — the engineer's placeholder; teal/cyan are recessive vs Tier 1 orange/purple so authoritative pins dominate), **sweeper = `truck.box.fill` cyan**. Tapping a reported pin → existing `PinDetailSheet` + `ReactionsRow`. **Tests 331 → 351/0**, RegionSyncGuard intact, #31-clean. QA PASS-WITH-NITS (`docs/qa/tier3-pr40-qa.md`).

**Tier 3 is now CODE-COMPLETE** across PRs #36–#40: typed-pin model → Tier 1 display → anonymous-auth + write path + reactions → universal reporting. The whole report→see→confirm/dispute→auto-resolve loop exists.

**⚠️ TO GO LIVE + verify end-to-end — Kevin's manual steps (the sandbox can't tap a sim or hold live creds):**
1. **Enable Anonymous Sign-ins** — Supabase → Authentication → Anonymous → enable (off by default; without it `signInAnonymously()` fails → no writes).
2. **Apply `supabase/02e-auto-resolve-trigger.sql`** in the SQL editor (the 3-dispute auto-hide).
3. **Manual smoke:** report a pin (long-press → Report, or in-drive Report button) → confirm the marker renders (teal enforcement / cyan sweeper) with the time-since badge → tap it → confirm/dispute via the ReactionsRow. This is the AC-R29/R40 verification nobody could do headlessly.

**Remaining Tier 3 work:** sub-PR #3 (decay *display* layer — opacity-fade + auto-removal at expiry; the time-since BADGE is already done in #40, so #3 may be minimal). **Follow-ups:** adopt supabase-swift SDK (→ Keychain + real Realtime, currently URLSession + polling), and 3 cosmetic PR #40 nits (a "Street sweeper" vs spec's "Sweeper passed" row label — accepted as clearer; 2 stale code comments).

### 2026-06-05 (later) — Tier 3 sub-PR #1 ships: anonymous-auth + crowd write path + reactions

**What landed:** **PR #39** (`d891763`). The first WRITE path + the reactions trust loop. `Services/SupabaseAuthService.swift` (silent `signInAnonymously()` on launch — no signup wall, per direction §6.3), `CommunityPinService` write methods (`insertCrowdPin` source='crowd'+author_id, `upsertVote` confirm/dispute on (pin_id,user_id), `callExtendPinExpiry` RPC), `PinDetailSheet` `ReactionsRow` (one-tap confirm/dispute + "Still there?", shown only for `lifespan==.ephemeral && source==.crowd`, A1 own-pin guard = iOS-only). Plus `supabase/02e-auto-resolve-trigger.sql` (`@backend-data`: auto-set `resolved_at` when `dispute_count>=3` on ephemeral crowd pins; on main, NOT yet applied to prod). **Tests 316 → 331/0**, RegionSyncGuard intact, #31-clean. QA PASS-WITH-NITS at `docs/qa/tier3-pr39-qa.md`.

**A3 SDK DEFERRED → follow-up.** Kevin approved adopting `supabase-swift`, but adding an SPM package WITHOUT opening Xcode (our pbxproj-autoformat rule) requires hand-building `Package.resolved` with exact checksums, which breaks `xcodebuild` on any mismatch. Engineer correctly stopped + fell back to **raw URLSession** (spec-authorized fallback; covers all ACs). **Follow-up PR to adopt the SDK** brings: Keychain session persistence (currently UserDefaults — QA nit #3), Realtime WebSocket (`startRealtime()` is a stub now — polling is the TF1 equivalent), and auto-resign on `.signedOut`. No API changes needed for the swap.

**Merge hiccup resolved:** the iOS engineer ALSO created `supabase/02e-...sql` (out of its lane — that was `@backend-data`'s deliverable, already on main). Add/add conflict at merge; resolved by taking backend's authoritative version, discarding the iOS one. Lesson: scope SQL deliverables to `@backend-data` only; don't let the iOS brief imply it should write the `.sql`.

**⚠️ CONFIG PREREQUISITES for the write path to work LIVE (Kevin's dashboard actions, like the schema apply):**
1. **Enable Anonymous Sign-ins** — Supabase Dashboard → Authentication → Sign In / Providers → **Anonymous Sign-ins → enable**. Supabase disables it by default; until enabled, `signInAnonymously()` fails and NO writes/reactions work. (QA confirmed this is a config prereq, not a code defect.)
2. **Apply `supabase/02e-auto-resolve-trigger.sql`** in the SQL editor (for the 3-dispute auto-resolve to fire).

**ReactionsRow not yet live-verifiable:** it only renders on ephemeral crowd pins, which don't exist until **sub-PR #2** (the patrol report UI creates them). PR #39's reactions UI is QA'd by code + tests only; live verification comes with sub-PR #2.

**Next — Tier 3 sub-PR #2 (W8.5f): the patrol report UI.** Long-press map → report `enforcement_active` / `sweeper_passed` (T3-1 first cut; T3-2 long-press entry; T3-3 time-since-badge decay). This creates the ephemeral crowd pins that the write path + reactions attach to — and unblocks live reactions testing.

### 2026-06-05 — Cruise Mode ("Find Parking") ships — destination-less Drive Mode

**What landed:** **PR #38** (`a4c6953`) — a destination-less Drive Mode for the most common NYC parking moment ("I'm already here, help me find a spot while I circle"). Follow camera + parking overlays + voice, no route/destination. Came in elegantly *subtractive*: the existing code already nil-guards route behavior on `activeRoute`, so it's a `DriveModeStyle` enum (`inactive`/`destination`/`cruise`, `patrol` reserved) + ONE guard on the final-approach handler + a pure-function `CruiseVoicePolicy` (announces only when a side is actually free/metered — silent on all-restricted blocks) + the entry UI. Reuses the existing camera (no fork, no second `.onChange(of: driveModeActive)`). **Tests 300 → 316/0**, RegionSyncGuard intact, #31-clean. New: `Services/CruiseVoicePolicy.swift` + tests; modified `DrivingContextService.swift`, `ContentView.swift`, `DriveModeBottomCard.swift`. Spec: `docs/cruise-mode-spec.md`. QA: PASS-WITH-NITS at `docs/qa/cruise-mode-pr38-qa.md`.

**Entry UX = combined native SwiftUI `Menu`** (Kevin's decision B, `docs/design/cruise-mode-button.md`): one toolbar drive-entry button → a native menu with "Drive to…" / "Find Parking nearby". Chosen over two separate buttons because **patrol mode adds a 3rd drive-entry** — the menu scales (add an item) where 3+ toolbar buttons wouldn't. Replaced a first-pass custom expand-pills implementation that truncated labels at the screen edge. Mute toggle lives in `DriveModeBottomCard` (now ≥44pt touch target; persists via `DrivingVoice.isMuted` ↔ UserDefaults `wepark_dm_voice_muted`, default on).

**⚠️ OUTSTANDING — manual tap-smoke needed:** a native SwiftUI `Menu` cannot be opened via `xcrun simctl` (no tap injection in the sandbox), so the **open-menu + cruise-active states are CODE-verified only**. Kevin should manually run the app and confirm: tap drive-entry → menu opens clean with both labeled options (no truncation) → "Find Parking" enters cruise mode (follow camera, parking overlays, voice on actionable blocks, mute toggle works). The collapsed-toolbar (single combined button) + #31-clean + 316/0 are sim-verified.

**Process notes:** (1) the native-menu polish agent was interrupted — committed locally, never pushed, left an orphaned *locked* worktree + lost its report; recovered by pushing the commit + force-removing the worktree, and QA became the primary verification. (2) QA caught 2 nits fixed pre-merge: a dropped `activeSheet == nil` guard (W8.5b regression — drive menu could fire over an open sheet) and a missing `accessibilityHint`. (3) Every engineering + QA agent this stream ran with `isolation: "worktree"`; `main` stayed clean throughout (branch-hijack norm held). (4) QA reports keep landing in the agent's worktree (worktree-relative-path trap) — rescued each time before pruning.

**Next:** back to **Tier 3 / patrol mode** — the Tier 3 OQ table (sub-PR #1 = anonymous-auth + reactions) is still pending Kevin's approval (`docs/tier3-patrol-mode-buildplan.md` + `docs/tier3-auth-and-reactions-spec.md`).

### 2026-06-04 (later) — Film-permit Edge Function deployed + 2 bugs fixed; cron is the one remaining (dormant) setup step

**Edge Function deployed via dashboard.** Supabase CLI couldn't install via brew (Command Line Tools flagged outdated; brew wanted to compile from source) — worked around by downloading the prebuilt `supabase_darwin_arm64` binary to `~/.local/bin/supabase` (v2.104.0; NOTE: it crashes if cwd contains a file named `supabase`, so run it from a neutral dir). But the CLI's auto-login needs a TTY (sandboxed Bash isn't one), so Kevin deployed `ingest-film-permits` via the **dashboard Edge Functions UI** (Deploy → Via Editor → paste `supabase/functions/ingest-film-permits/index.ts` → Deploy). Invocation tested via the dashboard's Test panel (the `sb_publishable_` key 401s a direct curl because the function has Verify-JWT on and that key isn't a JWT).

**Two bugs found + fixed live:**
1. **Socrata 400** (`edf6f8f`) — `enddatetime` is a floating timestamp; `toISOString()`'s trailing `Z` caused a SoQL type-mismatch. Fixed: `now.toISOString().slice(0,19)`. Verified the corrected query returns HTTP 200 against the live dataset.
2. **Missing `internal` schema** (`316be8b`) — `02d-ingest-cron.sql` created `internal.invoke_film_permit_ingest()` but never declared the schema; the paste would've failed. Added `create schema if not exists internal;`.

**Data-freshness reality:** the NYC film-permit dataset (`tg4x-b46p`) currently tops out at `enddatetime = 2026-03-20` (17,334 rows, none beyond), which is BEFORE the app's current date (2026-06-04). So a backfill ingests **0** permits right now — not a bug; the upstream data simply hasn't reached the current window. The pipeline is proven (deploy + auth + query all correct); real filming pins will flow once NYC's published permits overlap "now". **Kevin must re-deploy the Z-fixed function** (re-paste the corrected `index.ts`) so the live function + cron are correct — the version first deployed still has the `Z` bug.

**Cron is now LIVE** — scheduled 2026-06-04. The Vault secret `service_role_key` was created via the **`vault.create_secret(...)` SQL function** (the Vault BETA UI had no findable "add secret" button); `02d` applied clean; `cron.job` shows `ingest-film-permits` daily at `0 9 * * *`, active. Dormant until upstream NYC data reaches the current window. **One correctness TODO:** Kevin should still re-deploy the Z-fixed `index.ts` (the first-deployed version has the Socrata `Z` bug) so the daily run is correct once data exists. How the cron was set up (for reference):
1. Get the **legacy `service_role` JWT** (`eyJ…`) — Project Settings → **API Keys** page (`/settings/api-keys`), under a **Legacy API keys** section. (The new `sb_secret_` keys are NOT JWTs and won't satisfy the function's Verify-JWT; the cron needs the `eyJ…` one. If legacy keys are disabled, alternative is to turn OFF Verify-JWT on the function.)
2. Store it in **Vault** (Integrations → Vault → Secrets → Add new secret) as name `service_role_key`. (Vault is BETA in this project; the "add secret" affordance was hard to find — may need the Vault product enabled first.)
3. Run `supabase/02d-ingest-cron.sql` (already fixed + idempotent) in the SQL editor → creates `pg_cron`/`pg_net`, the `internal` schema + helper, `public.upsert_filming_pin`, and schedules `ingest-film-permits` daily at 09:00 UTC.
4. Verify: `select jobname, schedule, active from cron.job where jobname='ingest-film-permits';` → 1 row.

**iOS Supabase wiring (for any future sim build):** `ios/WePark/Config.xcconfig` (gitignored) now has `SUPABASE_URL = https:/$()/jiispshyqerscdoferaw.supabase.co` (the `$()` escapes the `//` so xcconfig doesn't treat it as a comment) + `SUPABASE_ANON_KEY = sb_publishable_…`. The smoke build is at `/tmp/wepark-smoke-build`.

### 2026-06-04 — Tier 1 goes LIVE in production + verified end-to-end (markers render from real Supabase data)

**Milestone: the community layer is on the map.** Kevin applied the schema to production Supabase (project `jiispshyqerscdoferaw`) via the SQL editor — `02-pins-schema.sql` + `02b-pins-ingest-indexes.sql`, both "Success." Then 2 test pins (filming @ SoHo, special_event @ LES) were inserted. The orchestrator wired `SUPABASE_URL` + the `sb_publishable_` anon key into `ios/WePark/Config.xcconfig` (gitignored), built the app for the iPhone 17 Pro sim, set sim GPS to each pin, and **screenshotted both markers rendering live** — purple `video.fill` filming marker + orange `star.fill` event marker — with the W7 ASP banner + full toolbar intact (NO #31 regression). **This closes AC-D11**, the end-to-end verification nobody had done: config wiring → anon SELECT → JSON decode → `.onChange` marker mount all confirmed working against production.

**Then ASP seeded:** `supabase/02c-asp-seed.sql` pasted/run in the SQL editor → **42 real 2026 ASP-suspension pins** (Jan 1 → Dec 25), idempotent upsert via the `pins_asp_suspension_date_uidx` dedup index. Validates the real-data upsert path the film ingest reuses.

**`@backend-data` built the automated ingest** (`5dcabea`): `supabase/02c-asp-seed.sql` (the seed above), `supabase/functions/ingest-film-permits/index.ts` (Deno Edge Function — Socrata `tg4x-b46p`, geocode fallback, upsert via dedup index, secrets from `Deno.env`), `supabase/02d-ingest-cron.sql` (pg_cron daily + `upsert_filming_pin` RPC fallback + Vault service-role key), and a 6-step deploy runbook at `docs/tier1-open-data-ingest-spec.md §9`. Meta shapes verified against `CommunityPin.swift` — no decode mismatch.

**xcconfig gotcha recorded:** `Config.xcconfig` reads `//` as a comment, which truncates `https://` URLs. Fixed with the empty-expansion escape: `SUPABASE_URL = https:/$()/jiispshyqerscdoferaw.supabase.co`. (Needed for any future iOS build/CI that wires Supabase.)

**Still open (Kevin's manual steps — no supabase CLI in this env):**
1. **Deploy the film-permit Edge Function** — needs `supabase` CLI installed (`brew install supabase/tap/supabase`) OR the dashboard Edge Functions UI, then the §9 runbook (deploy, set secrets, invoke once for backfill, apply `02d` cron). This is the only thing between here and *auto-flowing* real filming pins.
2. **Two test pins** (filming/special_event) left in prod — auto-expire in ~1-2 days; harmless, and currently the only map-visible markers until the film ingest runs.
3. **Two-tap detail sheet** (PR #37 QA nit #3) → `@designer` call in the pre-TestFlight pass.

### 2026-06-02 (later) — Community 1.0 Tier 1 display ships + product model locked (reactions, display surfaces, identity, open_spot)

**What landed on `main`:** **PR #37** (`9219c2e`) — Tier 1 read-only pin display. `Services/CommunityPinService.swift` (`@Observable`, 800ms-debounced PostgREST bounding-box fetch + Realtime stub, reads `SUPABASE_URL`/`SUPABASE_ANON_KEY` from config, fixture-driven for now), `Views/PinMarkerAnnotation.swift` (filming = purple `video.fill`, special_event = orange `star.fill`), `Views/PinDetailSheet.swift` (read-only). `asp_suspended_today` does NOT render as a marker — it **supplements the W7 ASP banner additively** (bundle calendar primary; a live pin can flip not-suspended→suspended for snow emergencies, never the reverse; `ASPSuspensionService` API untouched). Touched the two #31-class files (`ContentView.swift` body refactor + merged `.onChange(of: driveModeActive)`; `MapViewRepresentable.swift` annotation sync) — **QA confirmed no #31 regression** (toolbar + banner intact in smoke screenshot) and `RegionSyncGuardTests` still pass. **Tests 280 → 300/0.** QA: PASS-WITH-NITS (`docs/qa/community-1.0-ios-pr37-qa.md`).

**Product model locked this session (in `docs/community-1.0-direction.md`):**
- **Reactions = the trust engine** (not social): the `votes` table + "Still there?" decay IS the Waze loop. One-tap confirm extends/kills ephemeral-pin TTL; upvote/downvote feeds reputation on durable pins. §6.1.
- **Display surfaces** = layered + relevance-gated: map marker (always-on base) + push (pin near *your car*) + Drive Mode callout (pin on *your route*); **top banner reserved for zone-wide states only** (ASP-today, snow emergency). §6.2.
- **`open_spot`** added as a **Tier 3 beachhead experiment** — passerby-reported empty spot, distinct from the deferred occupant-handoff, cleaner legally, the "WE" non-parker-contributor play; brutal ~2-3min decay + "heading there" claim + reputation reward mandatory. §4/§5.
- **Identity = no signup wall** (resolves OQ-2): reading is anonymous-SELECT forever; reacting uses Supabase **anonymous-auth** (`signInAnonymously()`, silent device identity → satisfies `votes` uniqueness + reputation), with optional later **Sign in with Apple** upgrade that preserves history. Auth wiring is a Tier 2/3 task (Tier 1 display is read-only). §6.3.
- **Tier 1 display OQs resolved:** asp_today→W7 = supplement; include special_event; 800ms debounced region-change fetch; no marker clustering for TF1.

**Open items (gating live Tier 1 markers):**
1. **PROD SCHEMA APPLY = Kevin's dashboard task.** This env has NO supabase CLI / psql / creds, so the orchestrator cannot apply. Kevin runs `supabase/02-pins-schema.sql` then `02b-pins-ingest-indexes.sql` in the SQL editor (project **`jiispshyqerscdoferaw`**), verifies `select count(*) from public.pins;` = 0. Then `@backend-data` builds the ingest job against live tables, then Kevin does the **manual marker smoke** (AC-D11 — markers have NOT been visually verified by anyone yet; no live-data/inject path reachable in the sim; logic is unit-tested only).
2. **Two-tap detail sheet** (marker→callout→chevron) vs spec's implied one-tap — idiomatic MapKit; deferred to `@designer` call.
3. Doc-nit: a test inventory comment says "21 new" but it's 20.

**Process note (worktree isolation, refined):** PR #37 engineer + QA both ran with `isolation: "worktree"` — `main` stayed untouched the whole time (the branch-hijack fix held). New wrinkle: the isolated QA agent wrote its report to **its worktree's** `docs/qa/`, not main (the worktree-relative-path trap), so the orchestrator had to `cp` it out before pruning the worktree. **Lesson:** isolation prevents branch-hijack but means doc outputs land in the worktree — rescue them (or have the agent write to an absolute main-repo path) before removing the worktree.

### 2026-06-02 — Community 1.0 direction pivot + typed-pin foundation lands (model layer + schema, both QA-gated)

**Product pivot (discussion with Kevin):** Reframed the roadmap around a **two-segment funnel**, not a community-vs-core fight. The static parking-status data (rules, Drive Mode) stays the **critical piece** — it's the hero for the *novice/visitor* ("I can park free here, I never knew that") and delivers standalone value at zero users (the cold-start bridge). **Community is additive** — the real-time + correction *delta* layer that keeps the static rules *true today*, serving the *experienced parker* (reminders + exceptions). The two are a **flywheel**: experienced parkers are the supply side; their reports become the novice's value. Decisions Kevin locked: (1) **generalize the pin model to typed pins NOW** (foundational, not a later migration); (2) **re-aim the north-star** from Drive-Mode-only 70%-Yes fear-reduction to a 3-metric community-health dashboard (contribution density + active-reporter coverage + 7/30-day retention) with fear-reduction demoted to one Day-3 input. Enforcement-reporting reframed **evasion → compliance**: one neutral `enforcement_active` pin type (optional `meta.sub_tag`), copy is heads-up not "avoid tickets," cleaning-truck use leads (App-Store + city-relations risk drain). Direction doc: `docs/community-1.0-direction.md`; build plan + re-aimed metric: `docs/community-1.0-buildplan.md`.

**What landed on `main`:** Tier-0 foundation (the 3-codebase contract). `@tech-lead` wrote `docs/typed-pin-schema-spec.md` (10-type taxonomy, two-axis source/lifespan model as first-class columns) + the `supabase/02-pins-schema.sql` proposal. `@backend-data` finalized the schema (caught a real **frozen-`now()` partial-index bug**, added auth guard on `extend_pin_expiry`, two-axis indexes) + wrote `docs/tier1-open-data-ingest-spec.md` (film permits via Socrata `tg4x-b46p` + ASP seed; DOT/construction = TF2). `@ios-engineer` shipped **PR #36** (`162d273`) — `Models/CommunityPin.swift` (PinType + PinSource + PinLifespan + PinMeta associated-value enum + 10 meta structs, custom Codable) + decode tests. **Tests 243 → 280/0.** Model-only, no UI files touched → no smoke gate. **Schema QA: PASS-WITH-NITS, 12/12 ACs, 0 blockers** (`docs/qa/community-1.0-schema-qa.md`); nits cleared. **iOS PR QA: PASS-WITH-NITS, 280/0, 0 blockers** (`docs/qa/community-1.0-ios-pr36-qa.md`); 2 test nits cleared in an isolated worktree before merge.

**Still open (Kevin's explicit go required):** `supabase/02-pins-schema.sql` is **QA-clean but NOT applied to production Supabase** — the prod apply is the next gate. Then Tier 1 ingest build (`@backend-data`) + Tier 1 pin display (`@ios-engineer`) run in parallel (file-disjoint from Drive Mode). Patrol mode (W8.5e–i) is Tier 3's reporting UI — they converge, no double-build.

**⚠️ Process incident + new norm — agent branch hijack:** The `@ios-engineer` dispatch for PR #36 ran **non-isolated** in the shared working tree and **left its feature branch checked out**. The orchestrator's next several commits (docs, schema, QA reports, backend nits) silently landed on `ios/community-pin-model` instead of `main`; a later `git checkout main` made them appear to vanish (HEAD snapped back to `c232c75`). Nothing was lost — recovered via `git reflog` + cherry-pick onto `main` (the misplaced commits touched only `docs/`+`supabase/`, disjoint from the iOS files) + `git branch -f` to realign the feature branch to its remote. **New norm:** dispatch git-touching engineering agents with **`isolation: "worktree"`** (used on the very next dispatch — `main` stayed put), and **verify `git branch --show-current` after any non-isolated agent before the orchestrator commits** (`git log -1` shows the commit landed, not *which branch*). Recorded in `memory/feedback_agent_branch_hijack.md`.

### 2026-06-01 — W8.5d ships (final approach + arrival prompt + W7.5 auto-fire from arrival-confirm)

**What landed:** **PR #35** (`3685006`) — first novel destination-mode feature beyond the polish trilogy. **The parking-fear payoff moment.** Within 500m: voice elevates from 12s to 4s gap (more frequent parking commentary as you scan for a spot). Within 50m: arrival prompt fires asking "Park Here?". On "Park Here": pin saves at the user's CURRENT GPS (not the destination — they parked where they are), Drive Mode ends, W7.5 Park Until sheet auto-fires as the natural follow-up question. New `Services/FinalApproachService.swift` (pure static state machine), state-machine-driven voice gap (no double-gating with W8.5c's hardcoded 12s), approaching strip inside `DriveModeBottomCard`'s `.safeAreaInset` chain (no new layer to avoid #31 regression class), arrival prompt as a new `ActiveSheet.arrivalPrompt(coord:)` case with `ParkConfirmView`-pattern UX. Tests 228 → 243.

**Process / lessons:**

- **QA pass-1 caught a real spec-vs-code mismatch** that wasn't a code bug. AC-18 in the spec said "after arrival-confirm, the W7.5 Park Until sheet fires naturally via `pinDropped`." Code didn't do this. Reading the as-shipped W7.5 codebase showed the auto-fire was REMOVED in W7.5 pass-2 (pivoted to standalone-toolbar) — so the spec was stale; the code was correctly matching W7.5's actual behavior. **Kevin's product decision (Option B)**: the arrival-confirm path explicitly opts back INTO the auto-fire because the user has just committed to parking. This is the inverse of the commit-before-discover anxiety that drove W7.5's pivot, so the auto-fire is welcome here. Pass-2 wired `activeSheet = .parkUntil` after `endDriveMode()` in the arrival-confirm closure (verified `endDriveMode` doesn't clobber `activeSheet`).
- **The `.onChange`-driven architecture continues to hold.** W8.5d touched `ContentView.swift` (new `.onChange` handlers for `driveModeDistanceMeters` and `finalApproachState`), `DrivingContextService.swift` (voice-gap integration), and added `Services/FinalApproachService.swift` + `Views/ArrivalPromptSheet.swift`. Critically, `MapViewRepresentable.swift` was NOT touched — so the PR-3 region-sync fix is preserved by default and `RegionSyncGuardTests` continue to pass through unmodified.
- **Pure-function decisions continue to pay off.** `FinalApproachService.finalApproachState(forDistanceMeters:)` and `voiceGap(for:)` are trivially unit-testable (no `MKMapView`, no `CLLocation` deps); the 13 pass-1 tests + 2 pass-2 invariant tests covered boundary cases (>500, 500, 499, 51, 50, 49, 0, -5, nil) without needing any view fixtures. Same pattern as `paddingForBannerState` (PR-1), `targetPitch`/`shouldSyncRegionToBinding` (PR-3), `targetSpan`/`targetMapConfiguration` (PR-2).
- **No `headlessWindow` smell.** Engineer didn't add any production code to satisfy windowed-MKMapView tests. The auto-fire test is view-state-coupled but documented as deferred-to-Kevin's-manual-smoke rather than backdoored with test infrastructure in production.
- **Engineer-side test count comments had two consecutive off-by-ones.** Pass-1 inventory said "12 tests" but actual was 13 (extra 499m boundary test). Engineer's pass-2 fix corrected "12" → "14" but actual was 15 (13 + 2 new). Both are pure documentation noise — runtime behavior is correct, all 243 tests pass — but worth noting as a process pattern: engineers should `grep -c "func test"` to verify count claims. Fixed post-merge inline in this commit.
- **QA report inline-vs-disk friction recurred.** Pass-1 QA agent returned the report inline (perceived a "don't write .md report files" rule conflicting with the qa-verifier definition's "always write `docs/qa/<feature>-<pass>-<date>.md`" mandate). Pass-2 QA followed the explicit "write to disk via Write — do NOT return inline" instruction in the brief and did so correctly. Lesson: future QA briefs explicitly include the "your agent definition's `docs/qa/...` mandate supersedes any generic 'don't write .md report files' guidance" line.

**Kevin's manual smoke deferred** (sandbox cannot drive multi-tap Drive Mode flow): AC-25–28 — approaching-strip visibility, arrival-prompt fire at threshold, "Not Yet" survives in Drive Mode, polish trilogy continues working during final approach. The auto-fire to Park Until is also deferred; the sequence to manually verify is Drive Mode → search destination → Start Drive → use `simctl location start` to move toward destination → see strip appear within 500m → see arrival prompt within 50m → tap Park Here → see pin save + Drive Mode end + Park Until sheet appear immediately.

**Next stream:** Three credible paths:
1. **W8.5c-follow** voice calibration (the 4s gap is a reasoned default; drive-test informs whether it feels right) + Option B+ maneuver hint (single-line "Turn left on Prince St" text — deferred since 2026-05-30 pending drive-test feedback)
2. **Patrol mode (W8.5e–i)** — the master spec's second Drive Mode flow (cruising for parking without a destination)
3. **W8 / TF1 prep** — on-device install + drive-test + Mapbox token bundle-ID restriction + metrics infrastructure

Per master spec §7, sequence is normally destination-mode (done!) → drive-test → W8.5c-follow calibration → patrol mode → W8 TF1. The drive-test is the gating step. Once Kevin sets up direct Xcode install on his iPhone (~30 min one-time per the earlier discussion), the drive-test can happen this week and unblock everything downstream.

### 2026-05-30 — W8.5c-polish PR-2 ships, trilogy complete; Drive Mode now substantially Apple-Maps-feel

**What landed:** **PR #34** (`8f42e03`) — third and final atomic polish re-landing PR. **Auto-zoom (~0.005° span) + `.mutedStandard` map style + pitch re-eval 30° → 45° (renders faithfully at the tighter zoom) + directional user puck (custom annotation, mechanism b — no `userTrackingMode` conflict)**. All four features on the same Drive Mode entry/exit transition, single combined `setCamera` for pitch+zoom (R-2 design-time risk eliminated). Tests 214 → 228. Spec `docs/w8.5c-polish-pr2-spec.md`. QA `docs/qa/w8.5c-polish-pr2-pass-1-2026-05-30.md`.

**With this merge, the W8.5c-polish re-attempt trilogy is COMPLETE on main:** PR-1 (distance + z-order, 207/0) + PR-3 (3D tilt + setRegion-clobber fix, 214/0) + PR-2 (zoom + style + puck + pitch re-eval, 228/0). The original full polish PR #31 was reverted 2026-05-26 for a SwiftUI overlay regression; three atomic re-attempts each gated by a mandatory live-UI smoke shipped clean.

**Process / lessons:**

- **The 3-PR split + live-UI smoke gate paid off.** Each PR was independently smokeable + bisectable. The setRegion-clobbers-pitch bug (PR-3 pass-2) would have been near-impossible to diagnose if all 4 features had shipped in one PR — isolating tilt first made the clobber localizable to a specific transition. Lesson: post-revert re-attempts should default to atomic sub-PRs.
- **Kevin's manual smoke remains the visual acceptance gate for camera/animation/transition changes.** The sandbox cannot drive the Drive Mode multi-tap flow (Drive button → search → Start Drive). For PR-2's 4 features, the engineer's live smoke + QA's live smoke both confirmed launch-state overlay rendering (#31 regression check) but neither could verify the actual zoom/pitch/style/puck application during Drive Mode active. Kevin's manual smoke at Penn Station did. **This is now a documented invariant for the W8.5d / patrol mode work.**
- **Pitch empirical-measurement deferred to Kevin's smoke** (per spec OQ-2 acceptance path). Engineer couldn't drive Drive Mode headlessly to run the `print(camera.pitch)` measurement loop, so shipped 45° as reasoned default — and Kevin's smoke confirmed it renders faithfully (no MapKit clamp at the tighter ~1,035m altitude vs. PR-3's ~180,000m). Spec-fidelity preserved: engineer flagged the limitation rather than silently substituting.
- **The pre-existing PR-3 region-sync fix held.** `RegionSyncGuardTests` (2 tests) continued to pass through PR-2's changes — no `setRegion` calls leaked onto the Drive Mode active path. The architectural pattern from PR-3 (`.onChange`-driven, `CoordinatorActions` box, pure-function decisions, single combined `setCamera`) was successfully extended without regression.
- **PR-2 spec was written to the wrong directory by tech-lead** (worktree-relative `.claude/worktrees/.../docs/` instead of main repo `docs/`). Orchestrator moved it before engineer dispatch. **Add to tech-lead briefs**: spec files must land in the MAIN REPO's `docs/` not a worktree-relative path. (Minor process note.)
- **What's NOT done yet but visible from the polish trilogy**: Kevin's PR-2 smoke surfaced that real heading-up rotation can't be tested in sim (no magnetometer); the directional puck currently points "up" because the heading is 0. The only paths to verify heading-up: (a) `simctl location start` for straight-line movement (course-derived heading fallback may work; not realistic to actual streets), (b) Xcode GPX file route simulation (follows real routes, derives course from waypoints — most realistic sim option), (c) real-device drive-test (authoritative — pending carry-over since 2026-05-01).

**New + carry-over items going into W8.5d:**

- **Real-device drive-test** (carry-over since 2026-05-01): now genuinely blocks W8.5d design decisions. Kevin can install on his iPhone TODAY via direct Xcode install (no TestFlight needed — Apple Dev approved 2026-05-17 + Signing & Capabilities setup, ~30 min one-time). Drive-test informs: voice frequency (W8.5c-follow), font sizes at dashboard distance, whether the Option B+ maneuver hint is needed, W8.5d arrival escalation timing, heading-up smoothness on real GPS data.
- **Option B+ maneuver hint** (new, surfaced during PR-3 smoke): a single-line text strip at top during Drive Mode showing the next maneuver ("Turn left on Prince St"). NOT full nav, NOT voice. Rationale: iPhone has no PiP for nav apps, so users are one-app-at-a-time; without any maneuver hint they'll bail to Apple Maps for nav and forget WePark exists. Spec: needs tech-lead sub-spec. Decision: slot it in BEFORE W8.5d, ALONGSIDE W8.5d, or AFTER drive-test informs whether it's actually necessary. Lean: drive-test first (informs whether the gap really hurts), then decide.
- **Metrics + survey infrastructure** for the parking-fear-reduction success metric (per master spec §6): drive_sessions Supabase table, "pin drop within 10 min" tracking, the one-question survey at 3 days. NOT built yet — separate stream, needed before TF1 ships to actual beta users so we can measure whether WePark actually reduces parking anxiety.
- **Mapbox token bundle-ID restriction** (carry-over since W8.5a): still unrestricted on Mapbox dashboard. Must be scoped to `com.wepark.app` before any TF1 distribution.
- **Headless-window guard tech-debt** (carry-over since W8.5c-polish reverted #31): no current production code has this smell (it was reverted with the original polish, never re-introduced in PR-1/3/2). Lesson is durable in the agent norm; no code cleanup needed.

**Next stream:** **W8.5d (Final approach escalation + arrival prompt → W5 pin-drop hook)** per master spec §7. ~1 engineer session. Triggers at 500m threshold from destination, elevates voice frequency, shows "Approaching destination" visual strip, fires arrival prompt that hooks into the existing W5 `ParkPinService.pinDropped` flow. The architecture from PR-3/PR-2 (`.onChange`-driven, `CoordinatorActions` extensions, pure-function decisions) directly extends to W8.5d: the `applyDriveCameraPitch` doc-comment already notes "W8.5d note: this method is intentionally reusable for final-approach pitch escalation (e.g., increase pitch to 60° in the final 500m) without structural change." Tech-lead spec next.

### 2026-05-28 (later same day) — W8.5c-polish PR-3 ships (3D camera tilt) after a Kevin-smoke-only-catchable pass-2 fix

**What landed:** **PR #33** (`adebdc2`) — second of 3 atomic polish re-landing PRs. **3D camera tilt at 30° on Drive Mode entry, animated, restore-prior-pitch on exit.** Tests 207 → 214. Spec at `docs/w8.5c-polish-pr3-spec.md` (in PR). QA pass-1 at `docs/qa/w8.5c-polish-pr3-pass-1-2026-05-28.md`.

**Process / lessons:**

- **The `.onChange`-driven camera architecture works.** PR-3 implemented the spec's architectural fix: camera mutation lives entirely in a `.onChange(of: driveModeActive)` modifier in `ContentView` that calls a `CoordinatorActions` reference-type box wired in `makeUIView` — never inside `updateUIView`. QA pass-1 verified this structurally; the launch-state live-UI smoke verified the overlay-layer regression (#31) is not reproduced.
- **Kevin's first smoke caught a latent W8.5c bug that PR-3 exposed.** The tilt didn't visually apply in the sim. Diagnosis: `MapViewRepresentable.updateUIView` line 381 had `if driveHeading == nil { mapView.setRegion(region, animated: false) }`. `setRegion` (unlike `setCamera`) resets the camera to top-down (pitch 0, heading 0). The guard's intent was "skip during Drive Mode" but it used the wrong variable — `driveHeading == nil` conflates "no heading yet" with "not driving." In the sim (no magnetometer), `driveHeading` is ALWAYS nil → `setRegion` fired on every `updateUIView` during Drive Mode → wiped PR-3's pitch. This had been wrong since W8.5c; it only manifested now because PR-3 was the first thing to set pitch.
- **Pass-2 fix `4fb4f93`** (path A from the diagnosis): added `driveModeActive: Bool` property to `MapViewRepresentable`, extracted `shouldSyncRegionToBinding(driveModeActive:) -> Bool` pure function (returns `!driveModeActive`), gated the region-sync on it. The follow-during-drive mechanism turned out to already exist (`recenterDriveMap` in ContentView writes the `region` binding); the fix added a pitch-preserving `syncDriveRegion` coordinator method (uses `setCamera` with copied pitch/heading) to handle follow-while-active. **No `setRegion` calls remain on any Drive Mode code path.** Kevin's second smoke confirmed the tilt now visibly applies + no regression.
- **The bug was only catchable by Kevin's manual smoke.** The agent sandbox can't drive the Drive Mode multi-tap flow headlessly (Drive button → search → Start Drive). The live-UI smoke gate (added 2026-05-26) caught the launch-state regression check but couldn't reach Drive-Mode-active state. Tests didn't catch it because the pure `targetPitch` function is correct; the bug was downstream. **Lesson reinforced: tests + agent live-smoke + Kevin manual smoke each cover different failure modes; the agent smoke isn't a substitute for Kevin's eyes on interactive flows.** Add this explicitly to QA briefs for camera/animation/transition changes: "the agent cannot drive Drive Mode; Kevin's manual smoke is irreducible verification before merge."
- **PR-2 scope expanded based on Kevin's PR-3 smoke feedback.** Looking at the tilted-but-not-zoomed sim view next to Apple Maps' Drive view, Kevin identified three additions to PR-2's original auto-zoom scope: (a) re-evaluate pitch at the tighter zoom (MapKit clamped 45° → ~35° at the WIDE Drive Mode zoom, but may allow 45° or 60° without clamping at PR-2's tighter span — empirical test required), (b) `.mutedStandard` map style swap during Drive Mode (less colorful base map → better polyline legibility), (c) directional user puck (replace the round blue dot with an arrow). All three fire on the same Drive Mode entry/exit transition as auto-zoom, so they slot into PR-2 naturally — tech-lead spec will decide whether the puck bundles in or splits to PR-2.5 (the puck mechanism may conflict with the manual heading code).
- **Separate track flagged**: **Option B+ maneuver hint** — a single-line "Turn left on Prince St" text at the top during Drive Mode, no voice, no full ribbon. Kevin's PR-3 smoke surfaced the product tension: on iPhone there's no Picture-in-Picture for nav apps, so users are one-app-at-a-time. The Option B framing (run WePark + Apple Maps side-by-side) doesn't work in practice. Lite maneuver hint keeps users in WePark instead of switching out and forgetting. Not a quick polish add — needs its own tech-lead spec, separate from PR-2. Decide when to slot it in after PR-2 ships + drive-test informs whether it's necessary.

### 2026-05-28 — W8.5c-polish re-attempt PR-1 ships (distance indicator + End Drive z-order); live-UI smoke gate proves its worth

**What landed:** **PR #32** (`29dfe27`) — first of 3 atomic PRs re-landing the reverted W8.5c-polish. PR-1 = the two SAFE pure-SwiftUI pieces (distance indicator + End Drive z-order), explicitly excluding the camera code that was the suspected #31 regression cause. Tests 196 → 207. QA pass-1 + pass-2 at `docs/qa/w8.5c-polish-pr1-pass-{1,2}-2026-05-28.md`.

**Process / lessons:**

- **The new live-UI smoke gate (added to ios-engineer + qa-verifier defs 2026-05-26) did its job.** Both the engineer and QA built + launched the live app, `xcrun simctl io screenshot`'d it, and `Read` the screenshot (multimodal) to confirm the toolbar / ASP banner / overlay layer renders. No recurrence of the #31 silent-overlay-drop. This is the gate that would have caught #31; it's now standard for mount-chain PRs.
- **QA's code-read still caught what the smoke couldn't.** Pass-1's one blocker — `endDrivePillTopPadding` returned `0` for `.aspInEffect` (a visible-banner state) — only manifests on a normal ASP-in-effect weekday. Today (2026-05-28) is a suspension day, so the live smoke showed the red suspension banner, not the green `.aspInEffect` banner; the smoke could NOT surface the bug. QA caught it by reading the conditional. **Lesson reinforced: live smoke AND adversarial code-read are complementary, not redundant — neither alone is sufficient.**
- **Kevin's manual smoke validated the 44pt clearance magnitude.** Pre-QA, the orchestrator flagged that the fix used 44pt where the reverted #31 used 100pt. Resolved: the two values live in different safe-area contexts (the recenter toolbar manually clears status-bar + banner at 100pt; the End Drive pill respects safe area so 44pt is additional clearance below an already-banner-cleared position). Kevin's Drive-Mode-active screenshot confirmed the pill clears the red banner. Not a bug.
- **Two engineer/QA sub-agent socket drops this stretch, both recovered.** (1) The first PR-1 implementation attempt's socket dropped — a fresh engineer picked up uncommitted state and finished. (2) The QA pass-2 sub-agent's socket dropped after capturing smoke screenshots but before writing its report; the orchestrator executed the verification + wrote the report itself (independence preserved — orchestrator ≠ engineer). Pattern holds: commit early, and the main session is a reliable fallback when agents flake.
- **`@ViewBuilder` extraction was behavior-preserving.** Adding the distance indicator + z-order padding pushed `ContentView`'s body past the Swift type-checker complexity limit, forcing extraction of `driveModeOverlayLayer` / `bottomSafeAreaContent` / `sheetContent` into separate `@ViewBuilder` properties. QA verified the extraction didn't drop or reorder any `.safeAreaInset` / `.overlay` attachment — the regression-prone area, given #31.

**Next stream:** **W8.5c-polish PR-3** (3D camera tilt at 30° — the highest product value per Kevin: makes side-of-street parking attribution pre-conscious in a moving car), then **PR-2** (auto-zoom on Drive Mode start). Both re-implemented with camera changes driven by a `.onChange(of: driveModeActive)` modifier OUTSIDE `MapViewRepresentable.updateUIView` (the suspected #31 root cause — mutating UIKit state inside the update cycle races SwiftUI's mount), and with NO headless-window guard (tests restructured to use proper window fixtures instead). Each gated by the live-UI smoke. After the polish trilogy lands: W8.5d (final approach + arrival), real-car drive-test, W8.5c-follow voice calibration, patrol mode W8.5e–i, then W8 TF1.

### 2026-05-26 (later same day) — W8.5c-polish REVERTED + new "live-UI smoke-test before merge" hard gate

**What happened:** PR #31 (W8.5c-polish) merged at ~03:11 UTC, then reverted by Kevin at ~18:18 UTC after his post-merge sim smoke caught a real regression that QA missed by design.

**The regression:** After W8.5c-polish merged, the **entire SwiftUI overlay layer stopped rendering in the live app**:
- Toolbar buttons (gear / find-me / find-car / clock / Drive) — missing
- ASP banner at top — missing
- Park Until pill at bottom — missing
- Polylines still rendered, MapKit user-location dot still rendered, W5 parked-car pin still rendered. Only the `.safeAreaInset(...)` overlay chain was broken.
- Kevin also reported "longer app load + noticeable lag" — possibly related root cause (extra work on every `updateUIView`).

**Why QA missed it:** Tests passed 210/0 because they exercise `RouteService` + `DriveModeBottomCard` + camera transitions in isolation, not the live SwiftUI mount chain in a real app launch. The headless-window guard (production code added to `syncDriveCamera` so unit tests with bare `MKMapView()` work) raised a flag at QA — but QA verified its "never reached in production" claim only by reading the one production instantiation site at `ContentView.swift:303`, not by actually running the live app post-merge. Tests + static analysis weren't enough.

**Most likely root cause** (not yet diagnosed — reverted first to restore the live app):
1. Auto-zoom + tilt machinery in `MapViewRepresentable.updateUIView` firing synchronously during view construction, before SwiftUI finished mounting the `.safeAreaInset(...)` chain — preventing toolbar attachment.
2. OR the `headlessWindow` test-infrastructure guard inside `syncDriveCamera` actually firing in production despite QA's "never reached" claim — run-loop-pumping for 0.15s on every view mount would explain BOTH the missing overlays AND the perceived lag.
3. OR the `ContentView` change for End Drive z-order broke the toolbar's safe-area-inset attachment somehow.

**Revert:** `git revert 2df5603` produced commit `8036d25`. Five files deleted/reverted: 7 insertions, 1026 deletions. `docs/w8.5c-polish-spec.md` is gone from main; `ios/WePark/WeParkTests/W85cPolishTests.swift` gone. The spec-fidelity norm at `.claude/agents/ios-engineer.md` (commit `445e4a3`) is NOT part of the revert and stays on main — it was a separate commit unrelated to the polish PR's code. `docs/qa/w8.5c-polish-pass-1-2026-05-25.md` stays as historical record.

**Process / lessons:**

- **Tests + QA static-analysis are not enough for SwiftUI mount-chain regressions.** This is the second time a sub-PR landed with all-tests-green and live-app-broken (the W8.5a Info.plist `INFOPLIST_KEY_<custom>` bug was the first — that one Kevin caught via PlistBuddy on the built bundle). Tests verify what they're asserted to verify; they don't notice "the whole overlay layer is missing" because no test asserted "overlays present."
- **New hard gate**: before any squash-merge of an iOS PR that touches `MapViewRepresentable.swift`, `ContentView.swift`, `Views/DriveMode*.swift`, or any `.safeAreaInset(...)` chain, **the orchestrator must rebuild + reinstall + launch the live app in the sim and visually verify toolbar / ASP banner / Park Until pill (if applicable) all render**. This is now part of the merge ritual, alongside the existing `PlistBuddy -c "Print"` smoke for any PR that touches Info.plist keys. To be added to `.claude/agents/qa-verifier.md` AND `.claude/agents/ios-engineer.md` in a follow-up commit.
- **The QA agent's "verified never reached in production" claim for the headless-window guard was correct in spirit but insufficient in evidence.** Reading the one production instantiation site and confirming `mapView.window` *should* be non-nil there is a static-analysis assertion — it doesn't test the actual production behavior at runtime. To prove "never reached," QA would need to either (a) launch the live app and verify the guard's `print`/breakpoint never fires, or (b) instrument the production code with a `precondition` or assertion. Neither was done. This is a category of "the test is too easy" failure mode that we should add to QA briefs.
- **The spec-fidelity norm (added earlier same day) didn't catch this.** The norm catches silent SUBSTITUTION (engineer changing spec'd values without asking). It doesn't catch silent BREAKAGE (engineer's code works in tests but breaks at runtime). Different failure mode, needs different gate (the live-UI smoke gate above).

**Next stream:** **W8.5d (Final approach escalation + arrival prompt → W5 pin-drop hook)** per master spec §7. Build on W8.5c base (no polish). W8.5c-polish work is deferred until the live-UI smoke gate is in place and we can re-attempt with confidence. Tech-lead to spec W8.5d when ready; engineer brief will include the new live-UI smoke gate.

### 2026-05-26 — W8.5c-polish (Apple-Maps-isms) ships + new spec-fidelity norm + a near-miss silent-deletion save

**What landed:**
- **PR #31** (`2df5603`) — W8.5c-polish. Auto-zoom + 3D tilt + distance indicator + bottom card doc + End Drive z-order fix. Test count: 196 → 210 (+14). Spec at `docs/w8.5c-polish-spec.md`. QA at `docs/qa/w8.5c-polish-pass-1-2026-05-25.md`.
- **Commit `445e4a3`** (separate, ahead of #31 on main) — `docs(agents)`: added "Spec fidelity" section to `.claude/agents/ios-engineer.md` (14 lines). When a spec resolves an OQ to a specific value, engineer implements faithfully; if implementation reveals a constraint that makes the value impractical, engineer must STOP, surface, and ask for product approval. Same discipline for architectural decisions disguised as implementation details (production code paths for test infrastructure, MainActor/Sendable changes for tests, access-control loosening for `@testable import`).
- Closed 1 stream: W8.5c-polish.

**Process / lessons:**

- **The spec-fidelity norm exists because of this PR.** Engineer made two silent deviations during implementation:
  - Spec OQ-3 said pitch = 45°. Engineer hit a MapKit clamping behavior at the spec'd zoom (45° rendered as ~35° at altitude=99,999m), changed to 30° without asking. Kevin reviewed, accepted 30° on practical grounds (the difference is visually imperceptible at this zoom), but flagged the silent-substitution process miss.
  - Engineer added a production-code branch in `MapViewRepresentable.syncDriveCamera` whose sole purpose was synthesizing a `UIWindowScene` for unit tests that instantiate bare `MKMapView()`. Their words: "In production, `mapView.window` is always non-nil so this code path is never reached." Kevin accepted as tech-debt (restructure tests later), but again flagged the architectural smell of production code aware of test infrastructure.
  - **Both should have been flagged for product approval, not substituted in-flight.** Hence the norm.
- **QA caught a near-disaster pre-merge.** The polish branch was cut from `d3385b4` (pre-norm-commit). When QA ran, main was at `445e4a3` (post-norm). A squash-merge of PR #31 as-is would have silently DELETED the spec-fidelity norm from `.claude/agents/ios-engineer.md` — exactly the kind of silent deletion the norm exists to prevent. The QA verifier explicitly flagged this as Finding #1 (Major). Orchestrator rebased the branch onto main (preserving the norm), force-pushed with `--force-with-lease`, re-ran tests on the rebased state (210/0 confirmed), then squash-merged. **New checklist item for future post-norm-edit PRs**: if main has moved since the branch was cut, rebase before squash-merging — `gh pr view <#> --json baseRefOid,headRefOid` plus a manual check against `git log origin/main` before merge.
- **Both pre-accepted deviations are documented as "Accepted deviations / tech-debt" in the QA report**, NOT as Findings. The QA agent correctly distinguished pre-approved decisions from blocking issues.
- **Engineer process win**: the previous engineer agent's socket dropped mid-implementation. Follow-up engineer picked up the uncommitted state, read the 4 failing tests as a rubric, fixed the camera-transition logic + test infrastructure, and shipped 210/0 in one session. Pattern: **commit early and often** to make agent socket drops recoverable.

**Smoke confirmation (Kevin, iPhone 17 Pro iOS 26.4 sim, 2026-05-25 / W8.5c base):**
The W8.5c-polish work has not been smoke-tested against the live simulator yet — it shipped purely on test verification + QA approval. Worth a quick Drive Mode smoke when next at a laptop to confirm auto-zoom + tilt + distance indicator feel right in motion. Non-blocking; deferred to W8.5d.

**Still-open carry-overs after W8.5c-polish:**

- **Headless-window guard tech-debt** (new from this PR): test-infrastructure synthesis lives inside production `syncDriveCamera`. QA verified the "never reached in production" claim is true, but the architectural smell remains. Restructure tests so they no longer need the guard, then delete it. W8.5d or later.
- **Drive-test pending** (carried since 2026-05-01): Kevin's PWA Drive Mode v3 real-Manhattan drive-test informs voice-frequency / font-size / final-approach-UX calibration for W8.5c-follow.
- **Heading-up rotation real-device test** (carried since W8.5c): sim can't test (no magnetometer). Bundle with W8.5c-follow drive-test.
- **M-2 second-transition voice assertion** (carried since W8.5c): 12s min-gap guard blocks the second block-change assertion; needs DEBUG escape hatch. W8.5c-follow.
- **N-2 voice-rate test, N-3 DrivingContextService re-instantiation** (carried since W8.5c): advisory.
- **Mapbox token bundle-ID restriction** (carried since W8.5a): Kevin's out-of-band task before TF1.

**Next stream:** **W8.5d (Final approach escalation + arrival prompt → W5 pin-drop hook)** per master spec §7 (~1 session). Triggers at 500m threshold from destination, elevates voice frequency, shows "Approaching destination" visual strip, fires arrival prompt that hooks into the existing W5 `ParkPinService.pinDropped` flow. After W8.5d ships, drive-test + W8.5c-follow voice calibration, then patrol mode (W8.5e–i), then W8 TF1. Tech-lead writes a tight sub-spec first.

### 2026-05-24 — W8.5c (Drive Mode active layer) ships; smoke surfaces a polish PR scope

**What landed:**
- **PR #30** (`3fa59e0`) — W8.5c. Eight commits squashed: 5 pass-1 (N-1 lift → M-2 protocol seam + auth gate → continuous location → core services → heading-up rotation + tests) + 3 pass-2 (M-3 test comment + M-1 `authorizationStatus` seam + S-1 background-limitation alert). Test count: 149 → 196 (+45 W8.5c pass-1 tests + 2 BackgroundNoteGate pass-2 tests). Spec at `docs/w8.5c-drive-mode-active-spec.md` (in-PR diff, minor process deviation from convention). QA reports at `docs/qa/w8.5c-pass-{1,2}-2026-05-23.md`.
- Closed 1 stream: W8.5c. Drive Mode now has continuous GPS + heading, AVAudioSession ducking, AVSpeechSynthesizer voice with persisted mute, parking commentary engine with block-change detection, full-width bottom card, heading-up rotation with dead-band, wake lock, and a first-time background-limitation alert. All 3 W8.5b carry-overs (N-1 store lift, M-2 protocol seam, auth gate) resolved cleanly.

**Process / lessons:**

- **Engineer correctly avoided opening Xcode** this PR — no spurious pbxproj reorder (W8.5b's `a72292a` mistake did NOT recur). Continued "edit pbxproj from CLI only" discipline pays off.
- **QA pass-2 wrote the report to disk this time** (vs. W8.5b's inline-return recovery scramble). The explicit "write to disk via the Write tool" brief language worked. Keep the language.
- **The N-1 lift and M-2 protocol extraction were carried forward from W8.5b QA findings.** Pattern works: QA flags a deferred-but-mandatory carry-over → next sub-PR opens by clearing the carry-over → no carry-over backlog accumulates across multiple sub-PRs.
- **Kevin's smoke on 2026-05-24 surfaced real product-framing feedback the spec didn't predict**: he expected Drive Mode to feel more like Apple Maps (auto-zoom, 3D camera tilt, distance indicator). Per master spec §9 "Out of Scope (be aggressive)" — turn-by-turn ribbon, nav voice, speed/ETA row are explicitly OUT for v1.0 because they don't reduce parking fear. The intended workflow is Apple Maps + WePark side-by-side. Kevin chose **Option 2** — add a few Apple-Maps-isms (auto-zoom + 3D tilt + distance indicator) WITHOUT going full nav. Becomes the W8.5c-polish sub-PR (next stream).
- **Heading-up rotation is functionally correct but untestable in the iOS Simulator** — `simctl location start` updates GPS but doesn't simulate the magnetometer, so `CLHeading` updates don't fire. QA's unit tests passed (mocked headings), and the dead-band logic is correct, but live verification requires a real device. Filed as a real-device drive-test item.

**Smoke confirmation (Kevin, iPhone 17 Pro iOS 26.4 simulator at Penn Station 40.7506,-73.9935, 2026-05-24):**
- ✅ S-1 one-time background-limitation alert fires on first Drive Mode start, does not fire on second start (UserDefaults gate works)
- ✅ Voice commentary speaks parking availability on both sides as the simulated location crosses blocks
- ✅ Route polyline + red destination pin render
- ✅ Block-change detection works (voice announces on transitions, not every GPS tick)
- ❌ Heading-up rotation not visibly rotating in the sim (likely sim limitation — see real-device follow-up)
- ⚠️ Bottom card showed "Looking for street..." placeholder text in screenshot — needs verification that the left/right chip layout per spec actually renders when in-coverage of a recognized block
- ⚠️ End Drive pill visually overlaps the W7 ASP banner (cosmetic z-order issue)

**New carry-overs for W8.5c-polish (next stream):**

- **Auto-zoom on Drive Mode start** — set `MKMapView` camera to a closer zoom level when `driveModeActive` flips true (mimics Apple Maps "drive mode" zoom-in). Not in master spec §9 out-of-scope list — orthogonal addition.
- **3D camera tilt during Drive Mode** — set camera pitch for a driver-perspective view. Also not in §9 out-of-scope.
- **Simple distance-to-destination indicator** — a small text element (probably top-right of the bottom card or as a chip) showing distance remaining. NOT a speed/ETA row (that's explicitly §9 out-of-scope as "navigation scaffolding") — just distance.
- **Bottom card chip-layout verification** — confirm the spec'd left/right chip layout actually renders when a block is matched. Kevin's smoke screenshot showed "Looking for street..." placeholder; verbal report said chips updated. Possible bug, possible just transient state at screenshot moment. Tech-lead and engineer should verify by reading the rendering code + spec'ing a fix only if the chips are genuinely missing in the rendered state.
- **End Drive button / ASP banner z-order overlap** — cosmetic layout fix. End Drive pill should sit cleanly without obscuring the ASP banner copy.
- **Heading-up rotation real-device drive-test** — confirm the dead-band logic actually rotates the map on a physical iPhone (sim can't test). Bundle with the W8.5c-follow voice-calibration drive-test.

**Still-open carry-overs (deferred from W8.5c QA, expected):**

- **M-2 second-transition voice assertion**: 12s min-gap guard blocks the second block-change assertion in `testDrivingContext_blockChange_callsSpeak`. Needs a DEBUG escape hatch to bypass the guard for testing. Defer to W8.5c-follow when voice calibration is revisited.
- **N-2 `testDrivingVoice_speak_configuresCorrectRate` constant-check**: test asserts `AVSpeechUtteranceDefaultSpeechRate == 0.5` (framework constant) rather than actually verifying `DrivingVoice.speak()` sets the utterance rate. Would require AVSpeechUtterance spy/mock. Defer.
- **N-3 `DrivingContextService` re-instantiation**: re-created on every `driveModeActive` flip-true. Correct in common case; edge case for accidental tap-then-untap. Advisory, no action unless drive-test reveals an issue.
- **Mapbox token bundle-ID restriction** (carried since W8.5a): still unrestricted on Mapbox dashboard. Kevin's out-of-band task before TF1.

**Next stream:** **W8.5c-polish (Apple-Maps-isms + bottom card verify + cosmetic fixes)**. Per Kevin's product call: add auto-zoom + 3D tilt + distance indicator, verify bottom card chip rendering, fix End Drive overlap. Estimate: ~1–2 engineer sessions. Tech-lead writes a tight sub-spec first. After W8.5c-polish merges, the path is: W8.5d (final approach + arrival prompt → W5 pin-drop hook) → drive-test → W8.5c-follow (voice/font calibration from real-car findings) → patrol mode (W8.5e–i) → W8 TF1.

### 2026-05-23 — W8.5b (Destination input + routing UI + parking-aware scoring) ships

**What landed:**
- **PR #29** (`9436bd6`) — W8.5b. Six commits squashed: (1) `d745311` feat — scoring port + recent destinations + drive mode state; (2) `2fd03ec` test — fix blockKeyDedup test geometry; (3) `a72292a` chore — spurious pbxproj section reorder (build-system artifact, engineer-committed in error despite "don't open Xcode" brief — functionally inert, semantic diff is identical to main); (4) `b762c5a` fix — S-1 route polyline Z-order; (5) `695a8c5` fix — M-1 MKLocalSearch.start 10s timeout guard; (6) `40e0775` test — pass-2 S-1/M-1 verification tests. Test count: 126 → 149 (+21 core + 2 pass-2). QA reports: `docs/qa/w8.5b-pass-1-2026-05-20.md` + `docs/qa/w8.5b-pass-2-2026-05-20.md`. Spec at `docs/w8.5b-destination-routing-spec.md` with all 8 OQs resolved as tech-lead recommendations.
- Closed 1 stream: W8.5b (destination + routing UI for Drive Mode).

**Process / lessons:**

- **QA pass-1 found a Significant Z-order bug + Minor timeout gap; engineer fixed in pass-2; QA pass-2 verified clean.** S-1 was particularly important because the bug was *latent* in W8.5b (passive route display) but would manifest constantly in W8.5c when continuous location updates trigger tile reloads on every pan. Catching it in W8.5b QA was load-bearing — fixing it in W8.5b prevents introducing a regression as soon as W8.5c lands. Pattern: QA review of a foundation PR should ask not just "does this work now?" but "what happens to this code when the next sub-PR's behavior triggers it differently?"
- **Smoke confirms the spec's W8.5b scope.** Kevin's smoke on 2026-05-23 (simulator at Penn Station GPS) confirmed destination search → route fetch → blue polyline render → destination pin all work end-to-end. Kevin's own framing: "it wasn't a proper drive mode (which I think will be built in the sessions to come). The actual destination mapping looks good though." Exactly the W8.5b/W8.5c boundary as specced. No spec drift.
- **Engineer committed a spurious pbxproj section reorder as `a72292a`** despite the "don't open Xcode" brief. Functionally inert (same logical content, sections reordered). Squash-merged through but the merged diff against `main` includes the reorder. Next pbxproj edit will inherit this layout. **Continue to enforce "edit pbxproj from CLI only" in future engineer briefs.**
- **Pass-2 QA report was returned to chat instead of written to disk.** QA agent's tool calls didn't include the Write — the report content was in the response message. Recovered by writing the agent's verbatim response to `docs/qa/w8.5b-pass-2-2026-05-20.md` from the orchestrator session. **Future QA briefs should explicitly say "write the report to disk via the Write tool; do not return it inline" to avoid this recovery step.**

**Smoke confirmation (Kevin, iPhone 17 Pro iOS 26.4 simulator at Penn Station 40.7506,-73.9935, 2026-05-23):**
- Drive toolbar button → full-screen search opens, keyboard auto-focuses
- Type destination → MKLocalSearchCompleter results appear → tap a result → "Start Drive" appears
- Tap Start Drive → blue polyline renders end-to-end → red destination pin appears at target
- Verdict: ship as W8.5b scope; "real Drive Mode" UX (continuous location, voice, heading-up rotation) is W8.5c-d by design and not a regression

**New carry-overs for W8.5c:**
- **N-1 lift**: `RecentDestinationsStore` should move from inline-in-`DriveModeDestinationView.swift` to `Services/RecentDestinationsStore.swift` before W8.5c opens, in case commentary engine or arrival flow needs to read/clear recents. Small (~20 LOC move + import updates). Owner: `@ios-engineer` opening session.
- **M-2 error-path view test**: `testDriveModeDestinationView_routeError_doesNotCrash` per spec §6 was deferred — the view's `friendlyErrorMessage(for:)` + `errorBanner` paths have no unit coverage. Engineer's pragmatic note: `RouteService.shared` is a singleton without a protocol seam, so view-level error injection is non-trivial. Plan for W8.5c: extract a protocol so injection works, then add the deferred test. Owner: `@ios-engineer`.
- **Drive Mode entry should trigger location auth prompt** if not yet granted. Today, the app is "opportunistic" — only asks for location when the user taps the find-me button (W5.1 minimal scope). A user could tap "Start Drive" with location undetermined → `userLocation == nil` → route fetch fails with "Location unavailable" inline error. For W8.5c (which requires continuous location), the Drive Mode entry should call `LocationService.requestAndFetchLocation()` first if `authorizationStatus == .notDetermined`. Smoke-discovered carry-over from Kevin's pass-1 simulator test where the find-me button silently did nothing on a fresh sim install (simctl pre-grant unblocked it; real TF1 users won't have simctl). Owner: `@ios-engineer` at W8.5c opener.
- **Mapbox token bundle-ID restriction** (carried from W8.5a) — still unrestricted on the Mapbox dashboard. Must be scoped to `com.wepark.app` before TF1.

**Next stream:** **W8.5c (Parking commentary engine + voice + heading-up rotation + wake lock + continuous location)**. The big one — ports `getCurrentDrivingContext` / `speakDrivingContext` / `renderDrivingContext` from PWA `index.html`, adds `AVSpeechSynthesizer`, configures `AVAudioSession` with `.duckOthers`, `CLLocationManager.startUpdatingLocation` + `startUpdatingHeading`, `UIApplication.shared.isIdleTimerDisabled = true`, voice mute toggle. Per spec §7 W8.5c row: ~2 engineer sessions. Tech-lead may want to amend the spec based on W8.5b smoke findings before code starts. Drive-test pending — Kevin needs to drive-test PWA Drive Mode v3 (still open from 2026-05-01) to inform voice frequency and bottom-card legibility decisions before W8.5c locks design.

### 2026-05-20 — W8.5a (Mapbox HTTP Directions + RouteService foundation) ships

**What landed:**
- **PR #28** (`dfc93b2`) — W8.5a. Two commits squashed: (1) `5764182` feat — `RouteService` async/await wrapper around Mapbox Directions v5 + `DriveRoute`/`DriveRouteStep` models + 10 URLProtocol-mocked tests + `Config.xcconfig`/`Config.xcconfig.example` gitignore + initial `INFOPLIST_KEY_MAPBOX_ACCESS_TOKEN` wiring; (2) `53bb7c6` fix — replaced the dead `INFOPLIST_KEY_<custom>` setting with an `Info.plist` stub + `INFOPLIST_FILE` build setting so the token actually lands in the built bundle. Test count: 116 → 126 (+10 RouteService tests). QA report: `docs/qa/w8.5a-pass-1-2026-05-20.md`.
- Closed 1 stream: W8.5a (foundation for W8.5b-f Drive Mode).

**Process / lessons:**

- **The smoke gate caught a runtime bug that unit tests can't catch by design.** The mocked-`tokenProvider` injection pattern means RouteServiceTests never exercise the `Bundle.main` token-lookup path. So when the initial wiring (`INFOPLIST_KEY_MAPBOX_ACCESS_TOKEN = "$(MAPBOX_ACCESS_TOKEN)"`) turned out to be a silent no-op for custom keys, all 10 tests passed and QA's read-only Pass-1 review signed SHIP CLEAN — but `PlistBuddy -c "Print :MAPBOX_ACCESS_TOKEN"` on the built `.app/Info.plist` showed "Entry does not exist" in both Debug and Release. New checklist item for W8.5b+ and any future build-setting → Info.plist wiring: include a PlistBuddy smoke check on the built bundle as part of the engineer's hand-off.
- **`INFOPLIST_KEY_<name>` is allowlisted to Apple-defined keys.** Custom keys with that prefix are dropped. The correct pattern is `INFOPLIST_FILE = Info.plist` pointing at a stub with `<key>YOUR_KEY</key><string>$(YOUR_VALUE)</string>`; `GENERATE_INFOPLIST_FILE = YES` stays on and Xcode merges the stub with the auto-generated Apple keys.
- **Three engineer sub-agents stalled on this task across sessions.** Main session executed directly per the standing pattern. Independence per TEAM.md preserved because the QA agent ran fresh against the diff (and still missed the Info.plist bug — caught by Kevin's smoke).
- **Sub-PR sequencing works.** W8.5a foundation is now mergeable independently of UI; W8.5b can build on `RouteService.shared` with a stable API, and Kevin can drive-test destination-mode in real cars as soon as W8.5b lands without waiting for patrol-mode (W8.5f).

**Smoke confirmation (Kevin, real iPhone):**
- App regression check: all existing flows (recenter, ASP banner, pin drop, Park Until filter, notifications) still work
- Token validation: live Mapbox HTTP smoke from the local `Config.xcconfig` → HTTP 200, valid 5.3km / 23min NYC route

**Mapbox token housekeeping (out-of-band, owner: Kevin):**
- **Rotate the current `pk.*` token** on the Mapbox dashboard — a subagent briefly inlined the literal token bytes into the QA report (caught and redacted before any commit, low blast radius but cheap to rotate).
- **Add a bundle-ID restriction** (`com.wepark.app`) to the new token on the Mapbox dashboard before TF1 distribution. Currently the token is unrestricted; spec §4 calls for bundle-ID scoping.

**New carry-overs:**
- **`@MainActor` on `RouteService`** — consistent with `TileLoader`/`ToastService` precedent. QA flagged as advisory: W8.5b's location-update callback → `fetchRoute` path will hop to the main actor. Likely harmless given `async/await`, but worth revisiting if call-site latency becomes observable. See `docs/qa/w8.5a-pass-1-2026-05-20.md` M-1.
- **Multi-leg route handling** — current `MapboxRoute.toDomain()` flattens steps across all legs. For A→B with no waypoints (destination mode in W8.5b) this is always a single leg. Patrol mode (W8.5f) may produce multi-leg responses for sweep-waypoint chains; confirm step flattening is the right behavior when that lands.
- **Token redundant double-trim** — `bundleTokenProvider` trims, and `fetchRoute` trims again. Cosmetic nit; second trim catches test-injected whitespace tokens. See N-1 in the QA report.

**Next stream:** **W8.5b (Destination input + routing UI + parking-aware scoring).** Builds directly on `RouteService.shared.fetchRoute(from:to:alternatives:)`. Scope per spec §7: `MKLocalSearchCompleter`-backed search UI, route polyline rendered on the existing `MapViewRepresentable`, destination pin, `pickBestParkingAwareRoute` port from `index.html:6298` (OQ-4 = yes — scoring is mandatory), recent destinations in `UserDefaults`. New files: `Views/DriveModeDestinationView.swift`, additions to `RouteService.swift` for scoring. Estimate: ~2.5 engineer sessions. After merge, drive-test destination mode in a real car before W8.5c (commentary engine) starts.

### 2026-05-18 — W7.5 (Park Until X filter) ships + Apple Dev approval + W8/W8.5 reorder

**What landed:**
- **PR #27** (`7e372af`) — W7.5. Six commits squashed: engine `isFree(segment:from:until:)` interval-walker + 20 unit tests, ParkUntilSheet view with 6 preset pills + DatePicker, ContentView wiring (pass-1) → standalone clock.fill toolbar trigger (pass-2) → 7-day cap + relative-date format (pass-3). Test count: 96 → 116 (+20 engine tests). Spec at `docs/w7.5-park-until-x-spec.md` with §12 "As-Shipped Amendments" documenting the smoke-driven pivots.
- Closed 1 carry-over: W7.5 (this stream).

**Process / lessons:**

- **The smoke gate caught three things QA missed.** QA pass-1 (executed by main session after the 3rd consecutive qa-verifier sub-agent Bash flake) verified all 33 ACs by static analysis and gave SHIP CLEAN. Kevin's smoke caught: (1) commit-before-discover UX problem with pin-drop trigger → pivot to standalone toolbar (pass-2), (2) 24h cap too low for real use cases like weekend parking → raised to 7 days (pass-3), (3) ambiguous "Until 9:00 AM" label without date → relative-date format (pass-3). QA correctly verified what was spec'd; spec was wrong. Pattern continues to validate: smoke > QA > engineer-self-assessment.
- **Two parallel agents stalled at the 600s watchdog limit.** Tech-lead pass-2 spec amendment never wrote to disk. Ios-engineer pass-2 finished file edits but stalled at the verify step. Main session validated the engineer's disk state, ran tests, committed. Pattern continues: when sub-agents stall or hit Bash walls, main session finishes the work; independence per TEAM.md is preserved because main ≠ engineer sub-agent.
- **iPhone 17 Pro UDID destination still required.** Two simulators installed (iOS 26.4 + 26.5) make `name=iPhone 17 Pro` ambiguous; tests fail with "Mach error -308 (ipc/mig) server died" at runner install. Use `id=F0820726-15F4-4FA3-8602-A5D7B479A277` (the booted iOS 26.4 device) consistently. Worth keeping in the env section for future sessions.
- **Multi-day session continuity worked.** Kevin's computer closed mid-pass-2 yesterday. Session resumed today with disk state intact; engineer's stalled edits were validated and committed without rework. The pattern of "agents stall but their work product survives on disk" is a reliable recovery path.

**Apple Dev unblock (2026-05-17):** Apple Developer Program enrollment approved. W8 (TestFlight) is technically unblocked. Kevin's product decision: bring W8.5 (Drive Mode) INTO the MVP before TF1 launch rather than shipping TF1-MVP-only first and TF2-with-Drive-Mode after. Single complete-vision launch. New order: **W7.5 (done) → W8.5 Drive Mode → W8 TF1 with full vision** (no W9 needed). Per `docs/drive-mode-scope-spec.md` Option B: 4-7 engineer sessions, 1-3 weeks calendar time depending on how much real-Manhattan drive-testing Kevin can do. There are 4 open questions in `docs/drive-mode-scope-spec.md §0` that need Kevin's answers before code starts.

**Smoke confirmation (Kevin, iPhone 17 Pro simulator):**
- Pass-1 (pin-drop trigger): 5/5 mechanics work, but caught the commit-before-discover UX problem
- Pass-2 (standalone toolbar): 5/5 + Q1 (24h cap) + Q3 (date display) flagged
- Pass-3 (7-day cap + relative date): all good, merged

**New carry-overs:**
- **Custom-DatePicker / quick-pick state disconnect.** Kevin's pass-2 first screenshot showed the custom DatePicker at "May 19, 9:00 AM" but the confirm button label said "Confirm — until 12:00 PM." Two values didn't match. May indicate quick-pick state persists when user opens custom picker, OR the confirm button uses stale state. Pass-3's relative-date format made this harder to misread but didn't fix the underlying disconnect. Owner: `@ios-engineer` pass-4 if it reproduces in further smoke. Currently filed as observation, not confirmed bug.
- **W7.5 view-layer tests deferred.** ParkUntilSheet view + ContentView wiring tested by smoke only (engine has 20 unit tests). If TestFlight surfaces issues in the filter activation / clear flow, add `@MainActor` SwiftUI tests as a follow-up.

**Next stream:** **W8.5 (Drive Mode).** Kevin needs to answer the 4 OQs in `docs/drive-mode-scope-spec.md §0` first; tech-lead may need to amend the Drive Mode spec based on those answers; then `@ios-engineer` builds in 4-7 sessions across 7 sub-features (Mapbox HTTP Directions → parking-aware route scoring → top turn ribbon → voice tiers → heading-up rotation → re-routing → final-approach + arrival → pin-drop handoff). Each sub-feature could be its own PR for incremental drive-testing.

### 2026-05-16 (continued) — viewport-polish ships (W6.1 + viewport-polish in one day)

**What landed:**
- **PR #26** (`4264e60`) — viewport-polish. 4 commits: pass-1 (initial impl 289f4ab) + pass-2 (2 commits 9afbf13 + 9ef2724 for test/doc polish from QA findings) + pass-3 (192900b for camera-recenter fix from Kevin's smoke #5). Test count: 79 → 96 (+17 new). Files: `ContentView.swift`, `Services/Constants.swift`, new `WeParkTests/ViewportPolishTests.swift`. Spec at `docs/viewport-polish-spec.md` (status: "Spec locked, amended 2026-05-16" — Kevin's OD-1 cached-then-fresh GPS + OD-2 tile-bounds coverage check resolved).
- Closed 2 carry-overs: viewport-polish (this stream) and the W6.1-discovered "map behind sheet shows wide Manhattan" follow-up. New carry-over filed for polyline tile-load latency on deep-link cold-launch (the next-tier UX improvement, scheduled for post-W8 dynamic tile loading).

**Pass-3 was triggered by Kevin's smoke #5 catching a real bug QA missed.** The viewport-polish auto-center logic was placed in `.task { }` Priority 1 branch, which reads `appDelegate.pendingDeepLinkCarID` at view-mount. On cold-kill, the `AppDelegate.userNotificationCenter(_:didReceive:)` delegate fires AFTER `.task` evaluates → `pendingDeepLinkCarID` is still nil → Priority 1 fails → camera lands on `manhattanCenter`. The sheet still presents (W6.1's `.onChange(of: pendingDeepLinkCarID)` handler catches it later) but the camera was never recentered. Fix: add `recenterMap(on: car.coordinate)` to the W6.1 `routePendingDeepLink(_:)` helper. Now both paths (foreground-wake via `.task` Priority 1, cold-kill via `routePendingDeepLink`) recenter the camera. Idempotent on the path where both fire. QA pass-1 traced Priority 1 in `.task` by static reading and marked AC-B4 PASS without simulating the timing race. **Smoke caught what code review couldn't** — exactly the value of Kevin's hands-on smoke step.

**Process / lessons:**
- **iPhone 17 Pro simulator naming ambiguity.** Two `iPhone 17 Pro` devices installed (iOS 26.4 + 26.5) made `name=iPhone 17 Pro` an ambiguous xcodebuild destination — runs failed with "Mach error -308 (ipc/mig) server died" at test-runner install time. Fix: use `id=F0820726-15F4-4FA3-8602-A5D7B479A277` (the booted iOS 26.4 device) for deterministic targeting. Worth keeping in the env section for future sessions.
- **Engineer + QA agents continued the Bash-permission flake pattern.** Pass-2 engineer made all 4 source edits to disk correctly but couldn't commit/push (Bash denied). Same pattern repeats: main session executes the git operations + test verification while sub-agents do the file edits. The `memory/feedback_worktree_settings.md` note documents the worktree-local settings binding; the issue is sub-agents in this session keep getting locked-down policies regardless of the file allowlist. Practical workaround: main session handles git + tests; sub-agents handle code + analysis.
- **3-pass cycle for a "small" PR.** Viewport-polish was estimated as ~1 engineer session (~35 LOC). Real cost: pass-1 implementation (~35 LOC) + pass-2 cleanup (4 mechanical fixes) + pass-3 real bug fix (9 LOC fix in W6.1 helper). Kevin's smoke caught the only real bug. Pattern continues to validate: trust the smoke gate above the QA gate above the engineer self-assessment.

**Next stream:** **W7.5** (Park Until X filter — `@tech-lead` to spec). W8 TestFlight still blocked on Apple Dev approval.

### 2026-05-16 — W6.1 (deep-link replay) ships + viewport-polish spec locked

**What landed:**
- **PR #25** (`3c3ea10`) — W6.1: replaces `notificationDeepLinkSubject: PassthroughSubject<UUID, Never>` with `@Published var pendingDeepLinkCarID: UUID?` on `AppDelegate` (now `ObservableObject`). Dual-path routing in `ContentView`: `.onChange(of: pendingDeepLinkCarID)` for foreground/background-wake + `.onChange(of: scenePhase) { .active }` for cold-kill (iOS 17's `.onChange(of:)` doesn't fire on initial value, so the scenePhase handler is the only mechanism that catches a buffered carID present at view-mount time). `routePendingDeepLink(_:)` helper clears the buffer before routing — idempotent. Tests: 72 → 79 (+7 W6.1 tests). QA: pass-1 `docs/qa/w6.1-pass-1-2026-05-15.md` (SHIP WITH CAVEATS — only test-quality nits, addressed in pass-2 commits `71552f9` + `504e755`). Kevin smoked 3 critical scenarios 2026-05-16 (background-wake, cold-kill, mismatched-carID) — all pass.

**Process / lessons:**
- **First QA pass in the project where `xcodebuild test` was independently re-run.** Previous W7 QA passes hit unexplained Bash denials despite the worktree allowlist. The W6.1 brief explicitly instructed "try Bash first, don't bail without trying" — and it worked. Pattern worth keeping.
- **Engineer-vs-main-session division of labor for pass-2 fixes** continues to work well. W7 pass-2 had the engineer agent flake; main session did the fixes directly. W6.1 pass-2 the engineer ran cleanly. The independence invariant is preserved as long as QA is a fresh agent reading the diff cold — which it always is.
- **simctl smoke pattern documented end-to-end** for future notification-related work: read the parked car's UUID from the app's binary plist via Python `plistlib`, then `xcrun simctl push` with the carID in `wepark_car_id`. `simctl terminate booted com.wepark.app` simulates force-quit. Hardcoded UUIDs vs dynamically-derived: the dynamic approach is more faithful to production (Kevin pushed back on hardcoding and was right).

**New carry-over filed:** **viewport-polish** — Kevin caught during W6.1 cold-kill smoke that the map underneath the freshly-presented `ParkedCarDetailView` shows wide-zoom Manhattan default, not the parked car's area. Symptom = useful sheet over useless map. Tech-lead wrote `docs/viewport-polish-spec.md` covering (A) hide overlays at wide zoom (lower `polylineHideSpanThreshold` `0.1 → 0.04`), (B) auto-center on launch to user OR parked-car coordinate depending on context. Three priority paths spec'd (deep-link launch → parked car; normal launch → user location; fallback → Manhattan center). Two OQs for Kevin (fresh-vs-cached GPS; 25 km vs 15 km coverage radius). ~1 engineer session estimated. See "Carry-over deferrals" entry.

**Closed carry-overs:** W6.1 (this stream).

**Next stream:** **viewport-polish** (Kevin answer the 2 OQs → dispatch `@ios-engineer`) OR W7.5 (Park Until X — `@tech-lead` to spec). W8 TestFlight still blocked on Apple Dev approval.

### 2026-05-15 — W7 (ASP banner + settings + per-pin toggle + toast primitive) ships + SW cache bump + agent-permission lessons

**What landed:**
- **PR #23** (`f0f1b91`) — `sw.js` `CACHE_VERSION` `wepark-v32` → `wepark-v33`. Live PWA users finally evict the pre-PR-#21/PR-#22 tile caches on next visit. One-line fix that should have shipped immediately after the tile PRs landed; getting it out clears the only open infrastructure carry-over.
- **PR #24** (`01e80b8`) — W7. Five sub-features in one PR (banner + settings + per-pin toggle + sign-text expand + toast primitive). Tests: 60 → 72 (+12). New files: `ASPBanner.swift`, `SettingsView.swift`, `ToastService.swift`, `ToastHostView.swift`, `W7Tests.swift`. Spec at `docs/w7-asp-banner-settings-spec.md` (655 lines, locked with Kevin's 2 OQ decisions: omit Terms/Privacy footer link for v1, use toast banner — not silent toggle — to confirm global mute-off-→-ON).
- Closed 3 carry-overs: sign-text truncation (W7 §3.D), per-pin notification toggle (W7 §3.C), SW cache bump (PR #23).

**Process / lessons:**
- **Worktree-local `.claude/settings.json` binds for background sub-agents.** When the main session is in `.claude/worktrees/<name>/`, sub-agents I spawn inherit the worktree-local settings file, NOT the main repo's. Editing only the main repo's `.claude/settings.json` does NOT unblock background sub-agents — they auto-deny because they can't prompt the user. Discovered when the W7 engineer pass-1 attempt failed three times before I propagated the allowlist expansion (`Bash(git *)`, `Bash(gh *)`, `Edit`, `Write`) into the worktree's settings file. Foreground agents work fine because permission prompts surface live to Kevin. Saved to `memory/feedback_worktree_settings.md` so future sessions check both paths before launching background sub-agents from a worktree.
- **Engineer agent flaked on pass-2** despite the allowlist being correct — the agent assumed Bash was denied (without trying), bailed early. Main session did the 3 mechanical fixes directly (`private init()` + `#if DEBUG resetForTesting()`, `GeometryReader`-based safe-area inset, ToastService import cleanup). **Independence invariant preserved** because QA pass-2 was still spawned as a fresh agent reading the diff cold — TEAM.md's independence requirement is that QA ≠ engineer, not "main session ≠ implementer."
- **QA agents both denied Bash** in pass-1 and pass-2, blocking independent `xcodebuild test` re-runs. The 72/0 verification was done by the main session (Bash(xcodebuild *) was always allowed). Worth investigating whether `qa-verifier` needs a different permission profile, OR whether Bash should be granted for fresh QA spawns via `.claude/settings.json`. Carrying as a process issue, not a code issue.
- **Test verification chain:** engineer claims 72/0 → main session re-runs `xcodebuild test` directly post-fixes → reports 72/0 → QA pass-2 confirms by code inspection (no Bash) → Kevin's simulator smoke confirms behavior. The pipeline still works but is shakier than it should be — at least 1 of the 3 independent test runs needs to be machine-verified.

**Carry-overs added or unchanged:**
- New: **Terms of Service / Privacy Policy copy** — Kevin to draft when ready; non-engineering work.
- Unchanged: W6.1 deep-link tap flake (still open, ~half session), metered/other-category notifications (post-MVP), degenerate sub-segments (`@backend-data` cleanup), tile resource folder reference, etc.

**Smoke confirmation (Kevin, iPhone 17 Pro simulator):**
- Banner clearance (gear + recenter visible above green "ASP in Effect Today"): ✅
- Toast position clears Dynamic Island: ✅
- "Reminders re-enabled" toast appears above banner with correct z-order: ✅ (implicit via the above)
- Per-pin toggle round-trip (defaults ON in `ParkConfirmView`, editable in `ParkedCarDetailView`, persists across car-replace): ✅
- Sign-text tap-to-expand in `BlockDetailView`: ✅

**Next stream:** W7.5 (Park Until X filter — `@tech-lead` to spec) or W6.1 (deep-link flake — small engineer fix-pass).

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
