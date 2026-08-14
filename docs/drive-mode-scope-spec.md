# Drive Mode — iOS v1.0 Scope Decision

**Status:** Spec amended 2026-05-18 for W8.5 implementation (5 OQs + 3 NQs resolved + patrol mode added).
**Author:** @tech-lead
**Date:** 2026-05-12
**Amended:** 2026-05-18
**Supersedes:** Nothing — `docs/drive-mode-routing.md` is the PWA v3 reference and stays as historical context. This spec governs the iOS v1.0 question only.
**Related:** `docs/ios-mvp-spec.md` §2.2 (Drive Mode explicitly out of scope — this spec may change that); `docs/w5-pin-drop-spec.md` §6 (arrival → pin-drop hook intersection).

---

## §0 — Resolved Decisions + Open Questions for Kevin

### Resolved decisions (2026-05-17 — Kevin's answers, all 5 OQs closed)

**OQ-1: Option B — Vision-focused port. Confirmed.**
No full turn-by-turn ribbon, no re-routing, no Mapbox Navigation SDK. The destination input, parking commentary engine, final-approach escalation, and voice are the build targets. The §2 Options table below is preserved for history; it is not live scope.

**OQ-2: No drive-test gate before iOS build. Drive test already happened.**
Findings from Kevin's 2026-05-11 PWA drive captured in §11 are sufficient. iOS build starts now. Each sub-PR gets incremental drive-testing as it lands, rather than a single pre-build gate.

**OQ-3: Mapbox HTTP API. Hybrid option rejected.**
The "only valuable logic is parking score/free and distance to next block that has free parking" (Kevin's framing). That scoring requires guaranteed route alternatives, which MKDirections cannot provide deterministically in Manhattan. Mapbox HTTP (`MAPBOX_DIRECTIONS_URL` at `index.html:5987`) with `alternatives=true` is the single routing provider. No MKDirections fallback, no Navigation SDK. A new Mapbox token scoped to the iOS bundle ID is required (5-minute dashboard task — must complete before W8.5b starts).

**OQ-4: Yes — parking-aware route scoring required in v1.0.**
Kevin: "some version of parking-aware route scoring is going to be important." Direct port of `pickBestParkingAwareRoute` (`index.html:6298`, ~40 lines) to Swift. This was previously tagged as 0.5-session add (W8.5e) — it is now a mandatory work stream, not optional.

**OQ-5: TF1 — Drive Mode ships in TF1. No W9.**
2026-05-17 roadmap pivot: Drive Mode is bundled into the single complete-vision TF1 launch. The Option E (phased TF1-without-Drive-Mode, TF2-with-Drive-Mode) sequencing in §3/§7 is superseded. New order: W8.5 completes → W8 builds → TF1 ships.

### Resolved decisions (2026-05-18 — Kevin's answers, all 3 NQs closed)

**NQ-1: Dual-mode — commentary-only (default) + active turn-by-turn (opt-in). Confirmed.**
This is not a binary choice. Patrol mode ships with commentary-only as the default: the app speaks opportunities ("Free parking on your right") but issues no directional instructions. An in-session "Voice mode" toggle on the patrol bottom card switches to active turn-by-turn, where `PatrolModeService` feeds each next sweep waypoint into `RouteService` for a short route segment and W8.5d approach-escalation re-applies per segment. The toggle is session-scoped — patrol mode always starts in commentary mode; the user opt-in does not persist across sessions. Kevin's framing: "active turn-by-turn should be a feature but shouldn't be the primary feature." See §12 "Voice mode toggle" for UX detail.

**NQ-2: Voice + haptic pulse. Confirmed.**
`UIImpactFeedbackGenerator.medium` fires when a free block enters the 200m radius. No banner card. The haptic fires immediately after the voice cue completes — not during speech — to prevent overlapping sensory cues.

**NQ-3: Both explicit button + auto-detect (Option C). Confirmed.**
The patrol bottom card shows a persistent "I found a spot" button at all times. Auto-detect (speed < 2 mph for 10+ seconds) independently surfaces "Did you find a spot?" — both paths ship in W8.5. No conditional language; Option C is locked.

---

## §1 — Kevin's Vision

### Verbatim quote

> "Somebody driving into Manhattan, like myself, would put in a destination, and as they're driving around and approaching their destination, they would start seeing the parking availability around the street. For example, they would be two or three turns away from their target destination, and then they would start being told, 'Free parking on the right, free parking on the left until x, y, z,' something like along those lines, so that it's very obvious to the person that's driving where they can park for free. They can also get information like 'Metered parking on the right, no parking on the left.' All of that information is crucial to be displayed for ease of user experience, and there's a lot of fear about where a person should park. I'm hoping that this app clarifies that fear for them."

### Key insights

**1. Parking is the headline, navigation is scaffolding.**
The PWA built a navigation-first experience: full Mapbox turn-by-turn (Apple Maps-class ribbon, voice turn cues, progress bar, re-routing) with parking commentary layered alongside it. Kevin's vision inverts that priority. The user is already driving — they know how to get to their destination. WePark's job is to tell them what the street looks like from a parking standpoint as they approach.

**2. The "moment of value" is the final approach.**
"Two or three turns away from their target destination" is where commentary becomes proactive and loud. The earlier part of the drive is background. This means the app's most important behavior fires in the last ~500m of the trip. A feature that nails the final approach and is thin on the rest of the drive is more aligned with the vision than a feature that is full-fidelity for the first 90% and breaks on the last block.

**3. Both-sides-of-street commentary is the core feature.**
"Free on the right, metered on the left, free until X on the right" is stated three times in the quote in different forms. This is not incidental — it is the atomic unit of value. The PWA already does this: `speakDrivingContext(ctx)` at `index.html:5957` builds a phrase from `ctx.leftLabel.text` and `ctx.rightLabel.text`. The iOS port of this exact function is the beating heart of Drive Mode.

**4. Fear reduction is the explicit success metric.**
"I'm hoping this app clarifies that fear for them." This is the north star. Features should be evaluated by: does this directly reduce parking fear for the approaching driver? Navigation polish (re-routing edge cases, ETAs, speed readout) does not reduce parking fear. Proactive voice announcements on the final approach do.

---

## §2 — Options Evaluated + W8.5 Scope

### W8.5 scope (post-OQ resolution, 2026-05-18)

Two co-equal flows ship in W8.5. They share infrastructure (LocationService, Mapbox HTTP routing, AVSpeechSynthesizer, map overlay logic) but differ in trigger UI, routing strategy, and voice cue style.

**Destination mode** (original Option B scope — unchanged):
User enters an address. App routes them there via Mapbox HTTP with parking-aware alternative scoring. Commentary fires on every block change; voice and visual card escalate in the final 500m approach. Arrival prompt hooks into W5 pin-drop flow.

**Patrol mode** (new, 2026-05-18):
User has no fixed destination. User centers on current location or drops a "target area" pin. App identifies free blocks within a configurable radius using `ParkingRulesEngine.isFree(segment:from:until:)` (W7.5 engine), scores candidate streets via a direct Swift port of `pickBestParkingAwareRoute`, and generates a coverage-sweep route through the highest-scoring unvisited streets — direct port of the greedy graph traversal in `generateParkingRoute` (`index.html:7038`). Voice cues focus on opportunities, not turns. No "you have arrived" prompt; end-of-patrol has its own trigger (see §12 and NQ-3 above).

**Shared infrastructure:**
- `LocationService` (W5.1) — GPS stream, heading, speed
- Mapbox HTTP Directions API — destination mode uses it for route-to-destination; patrol mode uses it to fetch drivable sub-routes between sweep waypoints
- `AVSpeechSynthesizer` + `AVAudioSession` — both modes use the same voice engine (§5)
- `ParkingRulesEngine.isFree` (W7.5) — both modes query block status through the same interval-walker
- `MKMapView` overlay layer — both modes render on the same existing overlay architecture (W4 `MKMultiPolyline` groups)
- `ActiveSheet: Identifiable` enum (W5.1) — both modes add cases for their respective entry UIs

**File estimate uplift:**
Original Option B: ~4-7 sessions. Patrol mode adds: `PatrolModeService.swift` (~2 sessions), `PatrolView.swift` (~1 session), voice cue extension (~1 session), tests (~1 session). Revised total: see §7.

The options analysis below (A through E) is preserved as historical decision record. §3 recommendation is superseded by OQ-5 (TF1, not TF2).

### Option A — Full PWA Drive Mode v3 Port

**What it includes:** Mapbox Search Box destination input (with search-session token), Mapbox Directions API with `alternatives=true`, parking-aware route scoring (`pickBestParkingAwareRoute` at `index.html:6298`), full turn-by-turn ribbon (Apple-Maps-style with glyphs, distance, next-turn preview), turn-by-turn voice cues, heading-up rotation (`setDrivingMapRotation`), re-routing on deviation (`checkDeviationAndReroute`), arrival prompt, side-of-street highlights, parking commentary voice (`speakDrivingContext`), follow-mode with recenter button, speed/GPS accuracy meta row, wake lock.

**What this is not:** The PWA v3 as shipped did NOT have the "final approach prominence" that Kevin described. Commentary fires on every block change throughout the whole drive, not proactively on the 2-3 blocks before destination. The PWA's arrival behavior (`checkArrival` at `index.html:5853`) just prompts to set a car pin when stopped within 50m; it does not escalate voice commentary.

**Effort estimate:** 8–15 `@ios-engineer` sessions. The Mapbox Search Box UI alone (search-as-you-type, session token management, keyboard handling) is 2-3 sessions. The turn ribbon (glyphs, state machine, accessibility) is 2-3 sessions. Heading-up rotation with CoreMotion/CLHeading is 1-2 sessions. Each of these has its own QA pass. Plus: the PWA has never been drive-tested in real Manhattan conditions — you would be building on top of that uncertainty.

**TF1 delay estimate:** 6–10 weeks beyond Apple Developer Program approval.

**Risk:** This is the hardest option and the least aligned with Kevin's vision. It produces a navigation app that happens to have parking commentary, rather than a parking commentary app that happens to have navigation scaffolding.

---

### Option B — Vision-Focused Port (Recommended if Drive Mode ships in v1.0)

**What it includes:**
- Destination input: text field with `MKLocalSearchCompleter` (free, built-in, no third-party dependency) for address autocomplete.
- Route to destination: single route via Mapbox HTTP Directions API (or MKDirections — see §4). Draw route as a blue polyline on the existing `MKMapView`.
- **Parking commentary on every block the driver is on:** left/right side-of-street labels on a bottom card (port of `renderDrivingContext` / `getCurrentDrivingContext` from PWA). Fires on every `CLLocationManager` position update when block changes.
- **Final approach escalation (new, not in PWA):** When within ~500m of destination (2-3 city blocks), switch voice commentary from reactive (fires once per block change) to proactive (re-announces parking on each GPS update, approximately every few seconds). Visually, the bottom card background intensifies and a "Approaching destination" strip appears.
- **Voice commentary via `AVSpeechSynthesizer`**: "Left side, free until Thursday 9:30am. Right side, no parking." On block change throughout drive; more frequently in final approach zone.
- **Arrival prompt:** When speed drops to ~0 within 100m of destination, prompt: "Park here?" — links to the existing W5 pin-drop flow.
- **Heading-up map rotation:** `CLHeading` from `CLLocationManager` (already has `startUpdatingHeading()` in iOS). EMA smoothing, speed-gated (freeze rotation when stopped). Port from PWA's `stabilizedHeading`.
- **Wake lock equivalent:** `UIApplication.shared.isIdleTimerDisabled = true` (standard iOS pattern, no entitlements needed).
- **Follow-mode:** `MKMapView` recenters on user position on each GPS update. A "Recenter" button appears when user drags.
- **Exit Drive Mode:** single tap to dismiss. Restores pre-Drive-Mode map view.

**What it explicitly does NOT include (compared to Option A):**
- Mapbox Navigation iOS SDK (heavy, per-session billing — see §4)
- Full turn-by-turn ribbon with glyphs and step-by-step instruction audio
- Re-routing on deviation (can be v1.1)
- Parking-aware route scoring / alternative route selection (can be v1.1 — see OQ-4)
- Speed readout, ETA display, progress bar
- Mapbox Search Box (replaced with `MKLocalSearchCompleter`)
- Token modal / power-user token override

**What it adds that the PWA does NOT have:**
- Final-approach escalation (the most aligned-with-vision feature)
- Native `AVSpeechSynthesizer` with `AVAudioSession` coordination (vs. PWA's `window.speechSynthesis` which has no audio ducking)

**Effort estimate:** 4–7 `@ios-engineer` sessions. Breakdown in §7.

**TF1 delay estimate:** 2–4 weeks beyond Apple Developer Program approval.

**Risk:** The "no re-routing" choice means a user who misses a turn gets no automatic correction. Mitigation: the map re-centers on the user's GPS position at all times, so they can see where they are. Voice commentary continues regardless of whether they're on the planned route. The parking layer is spatial (not route-dependent) — blocks are always announced correctly even off-route.

---

### Option C — WePark as Commentary Layer on Top of Apple Maps

**What it includes:**
- User enters destination in WePark, taps "Start with Apple Maps."
- WePark constructs a `maps://?daddr=<encoded-address>&dirflg=d` URL and calls `UIApplication.shared.open(_:)`. Apple Maps launches in the foreground and handles all navigation, turn-by-turn, re-routing, ETA.
- WePark continues running in the background. `CLLocationManager` background-location entitlement must be enabled. WePark uses `AVSpeechSynthesizer` with `AVAudioSession.Category.playback` + `.interruptSpokenAudioAndMixWithOthers` option to duck Apple Maps voice and speak parking commentary when the user crosses a block boundary.
- A small persistent notification or App Clip-style pill in the Dynamic Island / lock screen lets the user return to WePark.
- "Approaching destination" detection: when haversine distance to destination < 500m, frequency and urgency of voice commentary increases.
- On arrival, WePark presents a local notification: "You've arrived — Park here?" returns to app, triggers W5 pin-drop flow.

**What it gives you for free:** Apple's navigation quality, traffic, re-routing, ETA, street-level guidance. Zero navigation engineering.

**Hard constraints:**
- Background location (`allowsBackgroundLocationUpdates = true` + `UIBackgroundModes: location` in Info.plist) requires the user to grant "Always" or "While using" location permission. "When in use" does not fire callbacks when Apple Maps is in the foreground. This is a real permission friction point — users may not grant "Always."
- `AVAudioSession` mixing with Apple Maps works via `.interruptSpokenAudioAndMixWithOthers` but has known issues: after `AVSpeechSynthesizer` finishes speaking, the session sometimes does not restore Apple Maps' audio promptly, causing a delay before Apple Maps resumes speaking. This is a confirmed iOS bug that has been open since iOS 16 (see Apple Developer Forums thread on `AVSpeechSynthesizer` session deactivation).
- The two-app split destroys the immersive WePark experience. Kevin's "it's very obvious to the person that's driving" language implies a single-screen, single-app context. With Option C, the parking commentary is audio-only while driving; the visual layer (the WePark map with colored blocks) is not visible while Apple Maps is in the foreground.
- Deep link opens Apple Maps unconditionally — it cannot return to WePark after launch. The WePark return requires the user to manually switch apps, or the lock-screen notification approach.

**Effort estimate:** 2–4 `@ios-engineer` sessions. The background-location + audio-session work is non-trivial (~2 sessions); the deep-link itself is ~20 lines.

**TF1 delay estimate:** 1–2 weeks beyond Apple Developer Program approval.

**Risk:** The "audio only, no visual" experience during the drive is a significant product regression from the vision. Kevin specifically said "they would start seeing the parking availability around the street" — the visual layer matters. Option C abandons the visual layer during the drive. Also, App Store review may scrutinize background-location use if the stated purpose ("parking commentary while navigating with another app") is ambiguous.

---

### Option D — Defer Drive Mode Entirely to v1.1

**What ships in TF1:** Everything in the current MVP plan (W5 pin drop, W6 notifications, W7 ASP banner, W7.5 Park Until X). Drive Mode lands in v1.1, 4-6 weeks after TF1.

**The cost:** WePark ships as a parking-management app (where did I park, when do I move) without the in-car drive-and-find experience. This is a coherent v1.0 story — it solves a real problem (ASP management, "where did I park") without solving the driving-search problem. The "fear reduction" value prop is not served in v1.0.

**The opportunity:** TF1 feedback from real users may reshape what Drive Mode should be. The drive-test (§8) should happen before Drive Mode code starts regardless of which iOS option is chosen. Deferring to v1.1 buys time to do the drive-test cleanly and let its findings directly inform the spec.

**Effort:** Zero incremental effort. No TF1 delay.

**TF1 delay estimate:** None.

---

### Option E (proposed) — Phased: TF1 ships Option D (pin + notifications), TF2 ships Option B

This is the recommended sequencing if Kevin chooses Option B (see §3). The app goes to TestFlight now with the parked-car management core. Drive Mode (Option B) ships 3-4 weeks later as TF2. This decouples the TestFlight timing from the Drive Mode build and lets Kevin drive-test the PWA before iOS Drive Mode coding starts.

Benefit over "wait for Drive Mode to do TF1": TestFlight feedback on the non-driving features (ASP banner, notifications, block colors) starts arriving sooner and informs v1.0 polish before the v1.0 GA. Drive Mode in TF2 gets its own focused QA pass.

---

## §3 — Recommendation (superseded by OQ-1 / OQ-5 resolution)

**This section reflects the original 2026-05-12 recommendation. It is superseded: OQ-1 = Option B, OQ-5 = TF1 (not TF2). W8.5 builds both destination mode and patrol mode for TF1. The rationale for Option B (below) remains valid and is not removed — it explains why the scope is what it is.**

**Original recommendation: Option E — ship TF1 without Drive Mode, ship Option B Drive Mode in TF2.**

Binding rationale:

1. **The drive-test has not happened.** The PWA's Drive Mode v3 has never been taken on a real Manhattan drive with a phone mounted on a dashboard. Per `HANDOFF.md` "Drive-test pending": this has been open since 2026-05-01. Building a native iOS Drive Mode on top of unvalidated PWA design choices is the single largest risk in this decision. Option E explicitly creates space for the drive-test to happen before iOS Drive Mode coding starts.

2. **Option B is the right scope.** It is directly aligned with Kevin's stated vision: destination input, parking commentary throughout, escalated voice and visual emphasis in the final 2-3 turns. Everything in Option A beyond this list — full navigation turn ribbon, re-routing, speed readout, Mapbox Search Box complexity — does not serve the fear-reduction goal. Option B adds one new feature the PWA does NOT have: final-approach escalation, which is the most vision-aligned piece. Option C's audio-only approach during the drive contradicts Kevin's "seeing the parking availability" language.

3. **Option B is achievable.** At 4–7 sessions, it is not an open-ended commitment. It can be spec'd cleanly with the same decision-density format as W4/W5. The parking commentary core (`getCurrentDrivingContext`, `speakDrivingContext`) is already proven in the PWA and is a direct port to Swift.

4. **Option D is a legitimate alternative** if Kevin's priority is time-to-market on TF1. The parked-car management story (pin, notifications, ASP banner) is a coherent v1.0. If Kevin wants TF1 in the minimum time possible, choose D and plan Option B for v1.1.

**One-sentence verdict:** Build Option B Drive Mode after TF1 ships (Option E phasing), with the PWA drive-test completing before iOS Drive Mode coding begins.

---

## §4 — Routing Provider Decision

### The constraint: Mapbox Navigation iOS SDK vs. Mapbox HTTP API vs. Apple MKDirections

**Mapbox Navigation iOS SDK**
- Full SDK via Swift Package Manager. Includes the `NavigationViewController` (turn ribbon, maneuver audio, progress UI — everything in Option A) and a separate `MapboxDirections` package for route calculation only.
- Billing: Navigation SDK v3 uses "Metered Trips" pricing. Free tier: **100 MAU / 1,000 trips/month** included. Above free tier: **$0.30/MAU/month** or **$0.08/trip** (whichever pricing model applies). At TestFlight scale (say 50 users, each making 5 trips/week = ~20 trips/month = 1,000 trips/month total), the free tier covers this exactly. Above 100 MAU the meter starts.
- Recommendation for Option B: **do not pull the Navigation SDK.** It is a heavy dependency, pulls in substantial binary size, and its main value (the pre-built turn ribbon UI) is not needed in Option B.

**Mapbox Directions HTTP API (no SDK)**
- Raw `URLSession` calls to `https://api.mapbox.com/directions/v5/mapbox/driving/<coords>?access_token=<token>&alternatives=true&geometries=geojson&steps=true`.
- This is exactly what the PWA already does (`MAPBOX_DIRECTIONS_URL` at `index.html:5987`, `fetchAndRenderRoute` at `index.html:6252`). The iOS port is a verbatim translation of ~60 lines of JS to Swift async/await.
- Billing: **Directions API is billed separately from the Navigation SDK**. Free tier: **100,000 requests/month**. Above that: $2.00/1,000 requests. At TestFlight scale (50 users × 5 trips/day × 30 days = 7,500 requests/month), this is well inside the free tier by a factor of 13.
- The existing Mapbox token in `tracker-config.js` (`pk.*` token, URL-restricted to `kevhox1.github.io` and `localhost:8765`) cannot be reused for iOS native HTTP calls — the iOS app's requests will not come from those URLs. A new Mapbox token will need to be created for the iOS bundle, stored in a `.xcconfig` file outside version control. **This is a 5-minute Mapbox dashboard task, but it must happen before Drive Mode code starts.**
  <br>**Correction (2026-08-13, see `docs/mapbox-token-security.md`):** the phrase above originally
  said this new token should be "restricted to the app's bundle ID via Mapbox's iOS SDK token
  restriction." That feature does not exist on Mapbox's dashboard — Mapbox only offers URL
  restrictions (web-only, explicitly incompatible with native SDKs) and per-token scope
  minimization (public vs. secret scopes). There is no bundle-ID / application-ID restriction
  analogous to Google Maps API keys. The correct control for the iOS token is: keep it separate
  from the PWA token (done), keep it out of version control (done, gitignored `Config.xcconfig`),
  and limit it to public scopes only in the dashboard. See `docs/mapbox-token-security.md` for the
  full writeup and Kevin's checklist.
- Parking-aware route scoring: `pickBestParkingAwareRoute` (`index.html:6298`) — 40 lines of JS — ports directly to Swift. If OQ-4 answer is "yes, include scoring," this adds one session of work. If OQ-4 is "no," skip it and use `alternatives=false` or just take the first returned route.

**Apple MKDirections**
- Free, no token, fully integrated with MapKit (already in use via `MapViewRepresentable`).
- `requestsAlternateRoutes = true` is supported and may return up to 2-3 alternatives — but the documentation notes that alternatives are returned "when available" at Apple's server discretion, with no guarantee. In practice, in dense urban grids (Manhattan), Apple does return alternatives, but the number and quality are not deterministic.
- Key limitation for parking-aware scoring: if only 1 route is returned, the scoring function (`pickBestParkingAwareRoute`) receives a 1-element array and trivially returns that route. This degrades the feature gracefully — scoring still works, it just has nothing to compare against.
- Turn-by-turn step data: `MKRoute.steps` returns `[MKRouteStep]` with `instructions` and `polyline` per step. This is usable for detecting which step the user is on and approximately how far from the next maneuver, but the instruction text is in Apple's format (not always identical to Mapbox). For Option B, which does NOT build a full turn ribbon, this does not matter — we only need the route polyline for rendering and the destination for arrival detection.
- **Recommendation for Option B: use MKDirections as primary, fall back to Mapbox HTTP if OQ-4 = "yes, include scoring with alternatives."** MKDirections is free, already integrated, and sufficient for Option B's reduced turn-by-turn scope. If parking-aware route scoring is required (OQ-4 = yes), add a single Mapbox HTTP fallback call for `alternatives=true` when MKDirections returns only one route.

**Recommendation summary:**
- Option B, parking scoring not required (OQ-4 = no): use MKDirections only. Zero external dependency, zero additional cost.
- Option B, parking scoring required (OQ-4 = yes): use Mapbox HTTP API for directions (mirrors the PWA exactly, stays in free tier at TestFlight scale, enables `alternatives=true` guaranteed). A new Mapbox token for iOS is required.
- Option A: Mapbox HTTP API for directions (same as above). Do not pull the Navigation SDK unless a full turn ribbon is required.
- Option C: No routing provider needed (Apple Maps handles navigation; WePark only needs CoreLocation for position tracking).

**The surprising finding on Mapbox pricing:** The Navigation SDK's free tier (100 MAU / 1,000 trips) is more restrictive than it sounds for a parking app. A daily commuter might make 2 Drive Mode trips/day = 60 trips/month. At 17 users making 60 trips/month, you hit the 1,000 trip/month free ceiling. Above that, $0.08/trip. For a TestFlight build this is negligible, but it argues against pulling the full Navigation SDK. The raw Directions HTTP API has a 100,000-request/month free tier — far more generous for early-stage usage.

---

## §5 — Voice + Audio Architecture

### iOS native voice: AVSpeechSynthesizer

`AVSpeechSynthesizer` is the correct API for Drive Mode voice on iOS. It replaces `window.speechSynthesis` from the PWA. Key differences:

- `AVSpeechSynthesizer` supports `AVSpeechSynthesisVoice(language: "en-US")` — pick a Siri-quality voice.
- Unlike the PWA's `speechSynthesis.cancel()` + `speak()` pattern (which causes a brief audio gap), `AVSpeechSynthesizer` can queue utterances and cancel mid-sentence via `stopSpeaking(at: .word)`.
- Rate/pitch are configurable: `AVSpeechUtterance.rate = AVSpeechUtteranceDefaultSpeechRate` (0.5) is appropriate for a moving vehicle. Slightly slower than the PWA's `rate: 1.0`.

### AVAudioSession coordination

The user will have music, podcasts, or navigation audio (if using Apple Maps in another app before switching to WePark) playing when Drive Mode starts.

**Recommended session configuration:**

```swift
// Configure once when Drive Mode activates
let session = AVAudioSession.sharedInstance()
try session.setCategory(
    .playback,
    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
)
try session.setActive(true)
```

`.duckOthers` lowers other audio (music) while WePark speaks. `.interruptSpokenAudioAndMixWithOthers` pauses spoken audio (podcasts, audiobooks) specifically during WePark's speech and resumes them after. This is the correct combination for a navigation-style app.

**Known issue:** After `AVSpeechSynthesizer` finishes speaking, the session does not automatically deactivate — other audio remains ducked until the session is explicitly deactivated. The fix:

```swift
// In AVSpeechSynthesizerDelegate
func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
}
```

`notifyOthersOnDeactivation` tells other audio apps (including Apple Maps if running in background) to resume at full volume. This is required — without it, Apple Maps navigation voice stays ducked.

**Option C audio interaction (WePark commentary over Apple Maps voice):**
Option C uses `.interruptSpokenAudioAndMixWithOthers` to duck Apple Maps' navigation voice while WePark speaks. The conflict scenario: Apple Maps announces "Turn left in 200 feet" and WePark simultaneously speaks "Left side, free until Thursday." Priority rule: WePark should NOT speak during the 5-second window before and after an Apple Maps maneuver cue. However, since WePark cannot observe Apple Maps' step state in Option C, this coordination is impossible to implement precisely. This is a material UX defect in Option C and one of the reasons it is not the recommendation.

**Voice mute toggle:** Mirror the PWA's `🔇/🔊` toggle. Persisted in `UserDefaults`. When muted, `AVSpeechSynthesizer.stopSpeaking(at: .immediate)` is called and no new utterances are queued. The audio session category is not changed when muted — stay in `.playback` to keep the session configured, but simply don't enqueue utterances.

**Wake lock equivalent:** `UIApplication.shared.isIdleTimerDisabled = true` when Drive Mode activates, `false` when it exits. No special entitlement needed. This prevents the screen from dimming while the user's phone is on the dashboard.

---

## §6 — "Fear Reduction" Success Metric

Kevin stated this explicitly: "I'm hoping this app clarifies that fear for them." Drive Mode without a success criterion ships into a void.

### Proposed metrics for v1.0 TestFlight

**Quantitative (in-app instrumentation — minimal, privacy-safe):**
- Drive Mode session count per user per week. (Is it being used?)
- Median Drive Mode session duration. (Are users staying in it for a whole approach, or bailing?)
- "Park here" pin-drop rate within 10 minutes of a Drive Mode session ending. (Did the session end in a parked car?)

These three can be logged as anonymous events in the existing Supabase backend (a new `drive_sessions` table with just `session_id`, `duration_seconds`, `ended_in_pin_drop: bool`, `created_at`). No PII needed.

**Qualitative (TestFlight survey — one question, shown once per user, 3 days after first Drive Mode use):**
In-app prompt (a simple alert or sheet): "When you used Drive Mode, did knowing the parking status of nearby blocks help you find parking more confidently?" — Yes / No / I haven't used it yet.

This is a binary fear-reduction question. A 70%+ "Yes" rate from early TestFlight users is the pass criterion for shipping Drive Mode in v1.0 GA.

**Drive-test qualitative (Kevin — before iOS build):**
Before Option B coding starts, Kevin completes the long-pending PWA drive-test (see §8). His qualitative feedback on what the PWA gets right and wrong in a moving car directly informs the iOS spec adjustments. This is the most important input.

**What does "shipped" mean in terms of success?**
Drive Mode is not a success if users activate it once and never return. The fear-reduction hypothesis is: "A first-time user who activates Drive Mode on their approach to a destination feels less anxious about finding parking than they would without it, and parks within 10 minutes of session end." The "pin drop within 10 minutes of Drive Mode end" metric is the closest proxy for this without surveying every user.

---

## §7 — Work-Stream Plan

### Sequencing (updated for TF1, 2026-05-18)

OQ-5 resolution: no W9, no pre-Drive-Mode TF1. The new order is:

```
[SHIPPED]  W5 → W6 → W6.1 → W7 → viewport-polish → W7.5   (all merged to main)
                                                                 ↓
                                                        W8.5 (Drive Mode — both modes)
                                                        Two sub-PRs recommended:
                                                          W8.5-dest (destination mode)
                                                          W8.5-patrol (patrol mode)
                                                                 ↓
                                                        W8 — TF1 build (Apple Dev approved 2026-05-17)
```

**Recommended sub-PR split:** destination mode and patrol mode can ship as two sequential sub-PRs within W8.5. Kevin can drive-test destination mode while patrol mode is still in development, which surfaces real-car feedback earlier. Patrol mode serializes after destination mode only for the shared foundation streams (W8.5a, W8.5c); its own service + UI streams can overlap partially.

### Destination mode work streams (W8.5-dest)

**All streams depend on W7.5 being merged (done as of 2026-05-16).**

| Stream | Owner | Parallelizable? | Est. sessions | Notes |
|---|---|---|---|---|
| **W8.5a** — CoreLocation drive session: `CLLocationManager` heading updates, `startUpdatingLocation` in drive mode, heading-up `MKMapView` rotation, follow-mode with recenter button, wake lock | @ios-engineer | Yes — no UI dependency | 1.5 | Port of PWA `stabilizedHeading`, `setDrivingMapRotation`, `recenterDriveMode`. `MapViewRepresentable` changes. Shared by both modes. |
| **W8.5b** — Destination input + routing: `MKLocalSearchCompleter`-backed search UI, Mapbox HTTP route fetch (OQ-3 = Mapbox HTTP, resolved), route polyline rendered on map, destination pin, parking-aware route scoring, recent destinations in `UserDefaults` | @ios-engineer | Yes — parallel with W8.5a | 2.5 | New `Views/DriveModeDestinationView.swift`, `Services/RouteService.swift`. **W8.5e (scoring) is now merged into this stream** — OQ-4 resolved yes, scoring is mandatory. Port `pickBestParkingAwareRoute` (`index.html:6298`, ~40 lines) as part of `RouteService`. |
| **W8.5c** — Parking commentary engine: `getCurrentDrivingContext` port, side-of-street labels on bottom card, `AVSpeechSynthesizer` voice, block-change detection, `AVAudioSession` configuration, voice mute toggle | @ios-engineer | Serializes after W8.5a | 2 | Port of `getCurrentDrivingContext`, `speakDrivingContext`, `renderDrivingContext` from PWA. New `Services/DrivingContextService.swift`, `Views/DriveModeBottomCard.swift`. Shared by both modes — patrol mode reuses the commentary engine with opportunity-style voice phrasing. |
| **W8.5d** — Final approach escalation + arrival: 500m threshold, elevated voice frequency, "Approaching destination" visual strip, arrival prompt → W5 pin-drop hook | @ios-engineer | Serializes after W8.5b + W8.5c | 1 | Not in PWA. Destination mode only. |
| **W8.5-dest Design** | @designer | Review W8.5c/d in parallel | 0.5 | Bottom card layout, approach strip, dashboard-mount font sizing. |
| **W8.5-dest QA** | @qa-verifier | After W8.5a+b+c+d merge | 1 | Destination-mode AC verification (AC-DM.1 through AC-DM.28 below + new AC-PM.* to be added). |

**Destination mode total: ~7–8 sessions.** Parallel execution of W8.5a + W8.5b saves ~1.5 sessions calendar time vs. serial.

### Patrol mode work streams (W8.5-patrol)

**All patrol streams depend on W8.5a (LocationService) and W8.5c (DrivingContextService) from destination mode.**

| Stream | Owner | Parallelizable? | Est. sessions | Notes |
|---|---|---|---|---|
| **W8.5f** — `PatrolModeService`: coverage tracking (`visitedBlockKeys: Set<String>`), street-graph rank (`scoreEdgeCoverage` port from `generateParkingRoute` at `index.html:7038`), next-street suggestion, loop-back / radius-expand logic, `ParkingRulesEngine.isFree` integration, Park Until filter integration | @ios-engineer | Can start once W8.5a + W8.5c are merged | 2 | New `Services/PatrolModeService.swift`. Port greedy traversal from `generateParkingRoute` (`index.html:7038–7152`). Key difference from PWA: PWA generates a static route up-front; iOS patrol mode re-ranks dynamically on every GPS update as new blocks are visited. |
| **W8.5g** — `PatrolView` + entry point: toolbar entry button, target-area pin (current-location default + drop-pin variant), patrol bottom card (free-block count, current suggestion, end-patrol button), `ActiveSheet.patrolMode` case | @ios-engineer | Parallel with W8.5f (different files) | 1.5 | New `Views/PatrolView.swift`. Adds `ActiveSheet.patrolMode` to W5.1 `ActiveSheet` enum. |
| **W8.5h** — Voice cue extension: opportunity-style phrasing ("Free parking 200 feet on right, free until 8 PM"), near-free cues ("Metered block ahead, free block 1 block further right"), stay-quiet logic for red/no-data blocks, throttling to avoid spam | @ios-engineer | Serializes after W8.5c + W8.5f | 1 | Extends `DrivingContextService`. New phrasing patterns — see §12 §"Voice cue style" for the spec. |
| **W8.5i** — Patrol mode tests: `PatrolModeService` coverage tracking, street ranking with mock graph, Park Until filter, no-data graceful degradation | @ios-engineer | Parallel with W8.5g | 1 | Target: `PatrolModeServiceTests.swift`. Minimum 10 test cases. |
| **W8.5-patrol Design** | @designer | Review W8.5g in parallel | 0.5 | Patrol card layout, free-block count chip, target-area pin visual, end-of-patrol prompt styling. |
| **W8.5-patrol QA** | @qa-verifier | After W8.5f+g+h+i merge | 1 | Patrol-mode AC verification (AC-PM.* below). |

**Patrol mode total: ~7.25–8.25 sessions** (NQ-1 dual-mode resolution adds ~1.25 sessions to this sub-PR: ~0.5 session for the "Voice mode" toggle UI, ~0.5 session for `PatrolModeService` → `RouteService` waypoint wiring, ~0.25 session for mode-switch tests).

### Combined W8.5 estimate

| Mode | Engineer sessions | Design | QA | Total |
|---|---|---|---|---|
| Destination mode (W8.5-dest) | 7 | 0.5 | 1 | ~8.5 |
| Patrol mode (W8.5-patrol) | ~5.75 | 0.5 | 1 | ~7.25 |
| **Total** | **~12.75** | **1** | **2** | **~15.75** |

With full parallel execution on disjoint streams, calendar time is closer to **9–11 sessions** rather than 15.75 serial. Revised range: **9–13 sessions** is the honest planning estimate (lower bound assumes maximum parallelism; upper bound assumes the usual integration friction).

The recommended staging: merge W8.5-dest sub-PR first (drive-test destination mode), then open W8.5-patrol. This means patrol mode can use destination-mode drive-test findings as real-world calibration.

### W7.5 / Drive Mode overlap

The "Park Until X" filter (`W7.5`) and Drive Mode share two integrations:

1. **Arrival flow (destination mode):** When Drive Mode detects arrival and triggers the W5 pin-drop, the W7.5 prompt ("Parking until when?") fires naturally from `ParkPinService.pinDropped`. No additional wiring — W5's existing `pinDropped` event covers this.

2. **Patrol mode routing (new):** If the user has Park Until active when entering patrol mode, `PatrolModeService` passes the `until` time to `ParkingRulesEngine.isFree(segment:from:until:)` when scoring candidate streets. This filters the sweep to only suggest blocks that are free for the full requested window. The `until` time comes from the existing `ContentView` state (the `parkUntilTarget` property set by `ParkUntilSheet`). No new state management needed — patrol mode reads the existing W7.5 target.

**Visual conflict (destination mode):** W7.5's Park Until filter colors blocks by the user's departure time; Drive Mode's bottom card shows real-time status. Resolution: Drive Mode always shows real-time status regardless of Park Until filter state. The Park Until filter remains active on the static map view for pre-drive browsing. Patrol mode is the exception — if Park Until is active, patrol mode uses the window for scoring but the bottom card still shows real-time labels (consistent with destination mode behavior).

---

## §8 — Drive-Test Dependency

### The pending drive-test

`HANDOFF.md` "Drive-test pending": "Kevin needs to take Drive Mode v3 out for a real Manhattan drive with phone mounted on dashboard. Voice timing, rotation smoothness, ribbon legibility while driving, side-highlight density — all need real-world feedback."

This has been open since 2026-05-01. The PWA's Drive Mode v3 is the reference implementation for iOS Drive Mode. **Building iOS Drive Mode on top of design choices that have never met real road conditions is a compounding risk.** If Kevin drives the PWA and discovers that:
- The voice fires too infrequently to be useful at driving speed (a real risk — block changes in Manhattan at 20 mph are rapid)
- The bottom card text is too small to read from a dashboard mount
- The heading-up rotation causes disorientation rather than clarity
- The side-highlight colors are not visible in direct sunlight on an OLED

...any of these findings would require design changes that propagate through the iOS spec before code starts. Doing the drive-test after iOS code is in progress means mid-stream rewrites.

### Recommendation

**Complete the drive-test before W8.5 coding starts.** This is compatible with Option E phasing: W5/W6/W7/W7.5 occupy 3-5 weeks of engineering. The drive-test can happen in parallel with those streams — Kevin can drive-test the PWA at any time; no engineering dependency. By the time TF1 ships and W8.5 scope is finalized, the drive-test findings will have been reviewed and incorporated into the W8.5 spec.

**Specific things to observe in the drive-test:**
1. Voice frequency: how often does the voice speak on a typical Manhattan block? Does it speak at every block change or miss some? Is the gap between announcements comfortable or anxious?
2. Bottom card legibility at driving speed and dashboard distance. What font size is needed? Is the left/right chip layout readable at a glance or does it require a focused look?
3. Heading-up rotation: does the heading-up map feel natural or disorienting? Is EMA smoothing sufficient, or does the map wobble at intersections?
4. Final-approach behavior (this is new, not in PWA): what does it feel like when the driver is 2-3 blocks away? Would an escalated voice announcement ("You're 2 blocks from your destination — free parking on your right") add clarity or feel annoying?
5. Side-highlight density: with 40,664 segments highlighted, is the map readable while driving, or is it visually overwhelming?

The drive-test findings should be written up in `docs/drive-test-findings.md` (by Kevin or a session note) and reviewed before W8.5 spec is finalized.

---

## §9 — Out of Scope (be aggressive)

The following PWA Drive Mode v3 features are **not being ported in v1.0 iOS Drive Mode.** Each has a rationale tied to Kevin's vision or practicality.

| Feature | PWA Location | Why out of scope for v1.0 |
|---|---|---|
| Full turn-by-turn ribbon (glyph + instruction + next-turn preview) | `updateTurnRibbon` at `index.html:6351`; `maneuverGlyphSVG` at `index.html:6400` | Does not reduce parking fear. Kevin's vision: "they would start being told" about parking, not navigation instructions. The user already knows how to drive to their destination. Defer to v1.1 if TestFlight users specifically request it. |
| Turn-by-turn voice instructions ("Turn left on Prince Street in 200 feet") | `speakTurnIfNeeded` (referenced in `onDrivingGeoUpdate:5854`) | Same rationale as turn ribbon. The parking commentary voice IS in scope; navigation voice is not. |
| Re-routing on deviation | `checkDeviationAndReroute` (referenced at `index.html:5857`) | High engineering cost for a low-fear-reduction benefit. Off-route users see the map re-centering on their actual position and can still receive parking commentary. Defer to v1.1. |
| Speed readout, ETA, distance remaining meta row | `updateBottomMetaRow` at `index.html:5915` | Navigation scaffolding, not parking. Adds visual clutter to the bottom card. |
| Mapbox Search Box (search-as-you-type with session token) | `MAPBOX_SEARCH_SUGGEST_URL` at `index.html:5985` | `MKLocalSearchCompleter` is free, built-in, and good enough for an NYC address lookup. The session-token management adds complexity without proportional user benefit. |
| Token modal (power-user Mapbox token override) | `openDriveTokenModal` at `index.html:6018` | Native iOS apps authenticate differently (token in `.xcconfig`, not user-entered). No power-user token override in native app. |
| `generateParkingRoute` coverage sweep | `index.html:7038` — greedy graph traversal for a "parking sweep route" | This is a completely separate feature (generate a loop route through parking-rich blocks, separate from navigate-to-destination). Interesting feature, but orthogonal to the Drive Mode destination-and-approach flow. Separate spec when/if needed. |
| Multi-stop trips | Not in PWA v3 either | Post-MVP. |
| Parking exposure scoring of alternative routes (if OQ-4 = no) | `pickBestParkingAwareRoute` at `index.html:6298` | Deferred per OQ-4. If Kevin's answer to OQ-4 is yes, this is a 0.5-session add-back (§7 W8.5e). |
| Heading smoothing via CoreMotion `CMMotionManager` | Not in PWA | The PWA uses GPS course-from-movement as a heading fallback. iOS `CLLocationManager.startUpdatingHeading()` provides `CLHeading` natively — no CoreMotion needed. |
| Side-of-street highlight polylines during drive (green/yellow overlay on current block) | `renderDrivingSideHighlights` in PWA | The static block colors (already rendered via W4's `MKMultiPolyline` overlays) serve this purpose. Separate per-side highlight overlays add rendering complexity without proportional gain. The bottom card's left/right chips communicate the same information textually. |

---

## §10 — Acceptance Criteria

"Drive Mode shipped" means all of the following are true:

**Entry and exit**
- [ ] **AC-DM.1** A "Drive" button is present on the main map screen. Tapping it enters Drive Mode. A visible exit control (✕ or "End Drive") dismisses Drive Mode and restores the pre-Drive-Mode map position and zoom.
- [ ] **AC-DM.2** Entering Drive Mode requests location permission if not already granted. If denied, Drive Mode presents an informational sheet explaining why location is needed and does not crash or enter a broken state.
- [ ] **AC-DM.3** `UIApplication.shared.isIdleTimerDisabled` is set to `true` when Drive Mode is active and restored to `false` on exit.

**Destination input**
- [ ] **AC-DM.4** Tapping the destination field activates `MKLocalSearchCompleter`. Typing a partial NYC address (e.g., "Spr") returns relevant suggestions within 1 second. Selecting a suggestion resolves to a `CLLocationCoordinate2D` and closes the keyboard.
- [ ] **AC-DM.5** User can skip destination input. Drive Mode functions (parking commentary, GPS follow, voice) without a destination. The route polyline and destination pin are absent.
- [ ] **AC-DM.6** Tapping "Start" with a destination triggers a route fetch (MKDirections or Mapbox HTTP per OQ-3). A blue route polyline appears on the map within 3 seconds on a good connection. A destination pin appears at the destination coordinate. The map does not crash or freeze if the route fetch fails — it falls back to no-route mode (AC-DM.5 behavior) with an error toast.

**GPS follow + heading-up rotation**
- [ ] **AC-DM.7** The map re-centers on the user's GPS position on each `CLLocationManager` update. The user pin (chevron / arrow icon, direction-indicating) is visible at all times in Drive Mode.
- [ ] **AC-DM.8** Map heading-up rotation: the map rotates to face the user's direction of travel when speed > 5 mph. When speed drops to 0 (stopped at light), the rotation freezes on the last known heading (does not spin back to north-up). When the user manually drags the map, auto-follow pauses and a "Recenter" button appears. Tapping "Recenter" restores follow mode.
- [ ] **AC-DM.9** Heading-up rotation passes the EMA stability test: heading does not change more than 15 degrees per GPS update when driving in a straight line at constant speed. (Verifiable in simulator by replaying a recorded GPX track.)

**Parking commentary — visual**
- [ ] **AC-DM.10** A bottom card is visible during Drive Mode. It shows: current street name; left-side parking label ("Free until Thu 9:30am", "Metered", "No Parking", or "—" if no data); right-side parking label in the same format.
- [ ] **AC-DM.11** The bottom card updates when the user crosses into a new block (street + from + to changes). It does not flash or blank during the transition — it updates smoothly.
- [ ] **AC-DM.12** Left/right labels are visually distinct (color-coded by severity: green = free, amber = metered, red = no parking, gray = no data). Colors match the W4.5 palette (6h threshold applies — a block free for 7 hours is green, a block free for 5 hours is orange).

**Parking commentary — voice**
- [ ] **AC-DM.13** `AVSpeechSynthesizer` speaks the parking context on each block change, using the format: "[Street name]. Left side, [label]. Right side, [label]." Example: "Spring Street. Left side, free until Thursday nine thirty AM. Right side, metered."
- [ ] **AC-DM.14** Voice obeys the mute toggle. Muting stops in-progress speech immediately (`stopSpeaking(at: .immediate)`). Unmuting resumes on the next block change.
- [ ] **AC-DM.15** When Drive Mode voice speaks, other audio (music, podcast) is ducked via `.duckOthers`. After speech ends, other audio returns to full volume within 1 second (verified by `notifyOthersOnDeactivation` in `AVSpeechSynthesizerDelegate`).
- [ ] **AC-DM.16** Voice rate is set to `AVSpeechUtteranceDefaultSpeechRate` (0.5). The full "Street. Left side, [label]. Right side, [label]." phrase completes in under 5 seconds for a typical label.

**Final approach escalation**
- [ ] **AC-DM.17** When the user is within 500m of the destination and a route is active, a visual "Approaching destination" indicator appears on the bottom card or as a top strip. The bottom card text size increases or the card gains emphasis (exact design per @designer review).
- [ ] **AC-DM.18** In the final approach zone, voice commentary re-announces on each GPS update (approximately every 3-5 seconds) rather than only on block change. If the user is on the same block for 30 seconds in the approach zone, voice re-announces every 15 seconds.
- [ ] **AC-DM.19** Voice is not spammed: a minimum 8-second gap between consecutive voice announcements in the approach zone, even if GPS updates arrive more frequently.

**Arrival**
- [ ] **AC-DM.20** When the user's speed drops below 2 mph within 100m of the destination coordinate for more than 8 seconds, an arrival prompt appears: "You've arrived. Park here?" with "Park here" and "Not yet" buttons. "Park here" dismisses Drive Mode and initiates the W5 pin-drop flow at the current GPS coordinate. "Not yet" dismisses the prompt without ending Drive Mode.
- [ ] **AC-DM.21** Arrival detection does not trigger if the user never set a destination (AC-DM.5 no-destination mode).

**No-data and edge cases**
- [ ] **AC-DM.22** Driving through an area with no tile data (e.g., near the Hudson River or a tile that has not loaded): bottom card shows "—" for both sides. Voice does not speak. No crash.
- [ ] **AC-DM.23** App backgrounded during Drive Mode: parking commentary and GPS updates continue if "When in use" location permission is granted and the app is in the task switcher. Full background operation (app fully dismissed) requires "Always" permission — if not granted, a one-time informational note explains this limitation on first Drive Mode use. No crash on backgrounding.
- [ ] **AC-DM.24** Rapid GPS updates (< 1 second apart): duplicate block-change events do not cause duplicate voice announcements. The block-key dedup (`street|from|to` comparison, same as PWA at `index.html:5905`) prevents this.

**Performance**
- [ ] **AC-DM.25** Drive Mode does not cause memory regression. RSS with Drive Mode active (GPS follow + voice) remains below 250 MB on iPhone simulator (same order of magnitude as W4's 137.5 MB baseline + reasonable overhead for `CLLocationManager` + `AVAudioSession`).
- [ ] **AC-DM.26** Map panning in Drive Mode (when recenter is disabled): no frame drops below 30 FPS visible to the naked eye while the polyline overlays are rendered. (Qualitative check — instrument if Drive Mode QA flags visible jank.)

**Regression**
- [ ] **AC-DM.27** All W5 acceptance criteria (AC-W5.1 through AC-W5.18) still pass after Drive Mode code is merged.
- [ ] **AC-DM.28** `xcodebuild test` reports all prior tests passing (45/0 minimum, as of W4.5 baseline) plus any new Drive Mode unit tests. No new `Calendar.current` usage introduced.

---

## Cross-references

- `HANDOFF.md` §"Drive-test pending" — superseded by §11 below. Kevin completed the drive-test 2026-05-11; findings captured in §11.
- `HANDOFF.md` §"Phase 5 progress" — W5/W6/W7/W7.5 must ship before W8.5 starts (Option E sequencing).
- `docs/ios-mvp-spec.md` §2.2 — Drive Mode is currently explicitly out of scope. If Kevin picks Options A/B/C, that line is superseded by this spec. Do not edit the mvp-spec directly; this spec is the override.
- `docs/drive-mode-routing.md` — PWA v3 reference spec. Read before starting W8.5b (routing). Not binding for iOS v1.0 scope decisions, but the architecture section (§Architecture, §Data flow) is a useful reference for the Swift port.
- `docs/w5-pin-drop-spec.md` §6.2 — the `pinDropped` hook that Drive Mode's arrival flow (AC-DM.20) will trigger.
- `docs/ios-color-threshold-spec.md` §8 — W7.5 "Park Until X" overlap with Drive Mode (§7 of this spec).

---

## §11 — Decisions Locked + Drive-Test Findings (2026-05-12)

Kevin reviewed the §0 open questions on 2026-05-12 and locked the following answers. All five align with tech-lead recommendations.

### Locked decisions

| # | Decision | Rationale |
|---|---|---|
| OQ-1 | **Option E (phased rollout)** | TF1 ships without Drive Mode; TF2 adds it. Decouples early TestFlight feedback from Drive Mode build time. |
| OQ-2 | **Drive-test already complete** (see findings below) | Kevin had already driven the PWA before this spec was written; findings supersede the "drive-test pending" carry-over. |
| OQ-3 | **Mapbox HTTP-only** (no SDK) | 100k req/month free tier covers TestFlight + early App Store scale. The Mapbox Navigation iOS SDK's 100 MAU / 1k trips free tier is too tight (verified 2026-05-12). |
| OQ-4 | **Yes — parking-aware route scoring is required in v1.0** | Kevin: "some version of parking-aware route scoring is going to be important." Reinforces Mapbox HTTP choice (MKDirections doesn't reliably return alternatives in dense Manhattan). 0.5 engineer-session add to Option B. |
| OQ-5 | **TF2** | Pin drop + notifications + ASP banner + Park Until X ship in TF1; Drive Mode ships in TF2. |

### Drive-test findings — PWA Drive Mode v3 in real Manhattan driving (Kevin, 2026-05-11)

Kevin completed the dashboard-mount drive test on the PWA. **The Drive Mode v3 experience was poor.** These are real-world product findings that must shape the iOS W8.5 / W9 spec when it is written.

**Reported problems:**

1. **User-location icon does not track movement well.** Visible lag and jitter between actual position and on-screen position. Likely root cause: browser `navigator.geolocation.watchPosition` has implementation-dependent update frequency and accuracy, often worse than native equivalents.
2. **One-way street direction is unclear on the map.** The PWA has `osm_oneway.json` data (NYC DOT centerline with TF/FT/TW direction flags) and uses it for routing, but the data is invisible to the user on the map. A driver can't see "this street is one-way the wrong direction" until the route already routes them around it.
3. **Lag during interaction.** General sluggishness — could be Leaflet DOM-based rendering, JavaScript main-thread blocking, or network latency for tile loads. Compounds the GPS tracking issue.
4. **Display quality is not great.** Vague but consistent — visual polish, contrast, readability from a dashboard mount under varying lighting. The PWA uses CSS that wasn't optimized for in-car readability.

### Why this matters for iOS Drive Mode (W8.5 / W9)

Each of the four PWA problems is **expected to improve significantly on iOS native:**

| PWA problem | iOS native expected improvement | Mechanism |
|---|---|---|
| GPS tracking lag/jitter | Large | `CoreLocation` with `kCLLocationAccuracyBestForNavigation`, `CLLocationManager.activityType = .automotiveNavigation`, native Kalman filtering by iOS. Much smoother than browser geolocation. |
| One-way direction unclear | Solvable | The `osm_oneway.json` data is in the iOS bundle (W2 brings the tiles + ASP data; one-way data can ship the same way). iOS can render directional arrows as `MKMapOverlay`s on each one-way street segment — a visual feature the PWA never built. |
| General lag | Large | UIKit + MapKit + Metal-backed `MKMapView` rendering vs. Leaflet + DOM. The W4 rendering refactor already demonstrated the order-of-magnitude difference (19.92 GB → 137.5 MB; 25× over Metal threshold → comfortably under it). |
| Display quality | Medium-Large | iOS Dynamic Type, dark mode, system color tokens, high-contrast accessibility settings. Custom UI components designed for dashboard mount distance + glare. |

**This validates the decision to build iOS native rather than continue investing in the PWA's Drive Mode.** Kevin's drive test was the experience that pushed him toward the iOS rewrite in the first place. The §1 vision (parking commentary as headline, fear reduction as success metric) sits on top of fixing these four foundational problems.

### Required additions to W8.5 spec — addressed in this doc

This spec (amended 2026-05-18) IS the W8.5 spec. The four PWA problems below are addressed in §7 (work streams) and the ACs in §10. See §10 AC-DM.7/8/9 for GPS accuracy, §9 for one-way visualization deferral, and the @designer stream in §7 for dashboard-mount polish. The items are preserved here as a checklist confirmation that all four were considered.

Anyone making future amendments must address each of the four PWA problems explicitly:

1. **GPS accuracy + update strategy.** Specify `CLLocationManager` configuration: `desiredAccuracy = kCLLocationAccuracyBestForNavigation`, `distanceFilter = kCLDistanceFilterNone` (every update), `activityType = .automotiveNavigation`, `pausesLocationUpdatesAutomatically = false` (driver doesn't want pauses on red lights). AC: user-position marker visibly tracks the car with < 1 second perceived lag.
2. **One-way street visualization.** Spec the visual treatment — likely a small arrow `MKAnnotation` mid-segment on each one-way street, only rendered at zoom 16+ (denser at higher zoom). Color matches palette doc gray.opacity(0.6). AC: a user can glance at the map and immediately see which streets are one-way and which direction they flow.
3. **Rendering performance.** No-regress AC: pan + GPS-follow + voice + route overlay at Manhattan zoom 17 stays at 60 fps on iPhone 15 and above; 30+ fps minimum on iPhone 12. Measured via Instruments.
4. **Dashboard-mount UI polish.** Designer must do a pass on Drive Mode UI specifically for dashboard-mount conditions: font sizes scaled up beyond Dynamic Type defaults, high-contrast color tokens, large tap targets for exit / mute, voice volume normalization. AC: Kevin (or another tester) reports the dashboard experience as "clearly better than the PWA" in a follow-up drive test.

### Re-test gate (updated for TF1)

Before iOS Drive Mode ships in TF1, Kevin (or a designated TestFlight tester) must drive-test the iOS build under the same conditions as the PWA drive test (Manhattan, dashboard mount, daytime) and confirm at least three of the four PWA problems are demonstrably improved. If fewer than three improve, hold the TF1 release and address findings. This gate applies to destination mode (W8.5-dest sub-PR); patrol mode gets a separate drive-test as its sub-PR lands.

### Updated work-stream sequence (amended 2026-05-18)

See §7 for the full updated work-stream table. Summary status as of 2026-05-18:

| Stream | Status | Notes |
|---|---|---|
| W5 — Pin drop | ✅ merged (PR #18) | |
| W6 — Notifications | ✅ merged (PR #20) | |
| W7 — ASP banner | ✅ merged (PR #24) | |
| W7.5 — Park Until X | ✅ merged (PR #27) | |
| W8 — TestFlight 1 | ⏸️ blocked on W8.5 completion | Apple Developer Program approved 2026-05-17. No pre-Drive-Mode TF1 (OQ-5 pivot). |
| **W8.5-dest — Drive Mode (destination mode)** | 📋 spec ready | Option B scope + parking-aware scoring (OQ-4 = yes). ~8.5 sessions. Sub-PR 1. |
| **W8.5-patrol — Drive Mode (patrol mode)** | 📋 spec ready (§12) | New — coverage sweep, opportunity voice, Park Until integration. ~6 sessions. Sub-PR 2. |
| W8 — TF1 build + TestFlight | ⏸️ blocked on W8.5-dest + W8.5-patrol | No W9 needed. Single complete-vision TF1. |
| v1.0 App Store launch | ⏸️ depends on TF1 feedback | Launch story: "WePark = Apple-Maps-class parking, including the in-car experience." |

---

## §12 — Patrol Mode Design (new, 2026-05-18)

### What patrol mode is and why it matters

Destination mode serves the occasional-driver use case: user is going to a restaurant, needs to park near an address. Patrol mode serves the everyday local use case: user is heading home to their neighborhood, has no fixed destination, and just needs to find the nearest free block. Kevin's framing: "covering ground in the most efficient way (centered around a target destination) until they find the free spot they are looking for." This is the dominant NYC street-parker behavior, and the PWA's `generateParkingRoute` (`index.html:7038`) already proves the concept — patrol mode is a dynamic, during-drive version of that static sweep.

### Entry points

Three options; recommend shipping the first two in W8.5:

**Option 1 — Toolbar button (recommended for W8.5):** A second icon in the bottom-right toolbar stack (next to the W7.5 clock icon) — e.g., a "radar" or "car-scan" SF Symbol such as `car.side.and.exclamationmark` or `scope`. Tapping it presents `PatrolView` as a sheet or enters patrol mode directly if no setup is needed. This is the lowest-friction entry point for the everyday-driver persona.

**Option 2 — Drive Mode entry toggle (recommended for W8.5):** When the user taps the "Drive" button and the destination input sheet opens, a "No destination — just find parking" toggle or button below the search field bypasses address input and enters patrol mode. This serves users who open Drive Mode and then realize they don't need a specific address.

**Option 3 — Long-press recenter button (defer to v1.1):** Gesture-based entry is less discoverable. Defer unless Options 1 and 2 prove insufficient.

Both Option 1 and Option 2 wire into the `ActiveSheet.patrolMode` case added to the W5.1 `ActiveSheet: Identifiable` enum.

### Target area selection

**Default (current location):** Patrol mode starts centered on the user's current `LocationService.userLocation`. The sweep radius is a circle centered on that coordinate. No extra UI required. This is the right default — the user is already driving in the area they want to park.

**Drop-pin variant (target area pin):** For the case where the user wants to park near a specific block but hasn't started driving there yet (e.g., "I want to park near Mott + Houston for dinner"). The `PatrolView` presents a small map with a draggable pin. User positions the pin, confirms. The sweep origin is the pinned coordinate instead of GPS position. The driving route to the sweep origin is fetched via Mapbox HTTP (same `RouteService` as destination mode) as the starting leg before patrol scanning begins.

**Which to ship in W8.5:** Both. The drop-pin variant reuses nearly all of the same infrastructure as current-location default (same `PatrolModeService`, same sweep logic, different origin coordinate). The `PatrolView` UI effort covers both.

### Routing strategy (PatrolModeService)

The iOS patrol mode dynamically ranks unvisited streets rather than generating a static path up-front. This is the key difference from the PWA's `generateParkingRoute`, which computes the full route once and renders it as a polyline.

**Data structures:**
- `visitedBlockKeys: Set<String>` — set of `"street|from|to"` keys for streets already driven (populated from GPS position updates)
- `coveredEdgeIDs: Set<String>` — directed edge IDs from the street graph to prevent re-suggesting
- `sweepOrigin: CLLocationCoordinate2D` — the center of the patrol area (current location or drop-pin)
- `sweepRadiusMeters: Double` — configurable, defaults 600m (~5 Manhattan blocks in any direction). Expands by 200m increments if no free blocks remain within current radius.

**Next-street ranking algorithm (port from `generateParkingRoute`):**
1. Get adjacent unvisited directed edges from current street-graph node (respects one-way direction — same `streetGraph.adj` structure as PWA's `generateParkingRoute` at `index.html:7079`).
2. Ban immediate U-turns (same logic as PWA line 7104).
3. For each candidate edge, compute `freeBlockScore`: count of `isFree` segments on both faces of that street using `ParkingRulesEngine.isFree(segment:from:until:)`. If Park Until is active, pass the `until` time; otherwise pass a 2-hour default (reasonable for "I need to park soon").
4. Bonus for edges closer to `sweepOrigin` (keeps the sweep centered).
5. Large penalty (-100 × visitCount) for revisited edges.
6. Pick highest-scoring candidate. If all candidates score ≤ 0, expand sweep radius and retry.

**Voice mode: commentary-only (default) + active turn-by-turn (opt-in toggle):**
Patrol mode always starts in commentary-only mode: the app announces opportunities ("Free parking ahead on right") but does not issue directional instructions. This is the primary behavior.

A "Voice mode" toggle on the patrol bottom card — an icon button in the card's secondary control row (e.g., `waveform` vs. `arrow.turn.up.right` SF Symbol pair) — switches between Commentary and Turn-by-turn for the current session only. The toggle does not persist; every new patrol session starts in Commentary mode.

**Toggle UX:**
- Location: secondary icon row on the patrol bottom card, to the left of the mute button. @designer to confirm final placement (acceptable fallback: a single icon in a small overflow menu if card real estate is tight).
- Visual state: the active mode's icon is tinted with the app accent color; inactive is gray. A short text label ("Commentary" / "Turn-by-turn") appears adjacent to the icon for accessibility — hidden at compact width, visible at regular width.
- Mid-patrol switch feedback: a brief toast ("Switched to turn-by-turn") appears at the top of the patrol card for 2 seconds. `AVSpeechSynthesizer` speaks a single confirmation: "Turn-by-turn on" or "Commentary mode on." This overlaps with no other queued cue — if a parking cue is in-flight, the confirmation is deferred until the queue clears.

**When Turn-by-turn is active:**
`PatrolModeService` feeds the next highest-scoring sweep waypoint as the destination into `RouteService.fetchRoute(to:)` — the same route fetch used by destination mode. A short route segment (typically 1-3 blocks) is returned. W8.5d's approach-escalation logic re-applies for each segment: when the user is within ~100m of the next waypoint, the voice escalates ("Turn right on Spring Street to reach a free block"). On arrival at the waypoint, `PatrolModeService` selects the next candidate and fetches a new segment. The route polyline updates on the map to reflect the current segment. Commentary cues continue in parallel — turn-by-turn augments but does not replace the "free block ahead" spatial announcements.

**Coverage radius behavior:**
- Default radius: 600m from sweep origin.
- When all unvisited edges within the current radius score ≤ 0 (all no-data or no-parking), expand by 200m up to a maximum of 1,500m.
- If max radius is reached and no free blocks found, surface a "No free parking found in this area" voice cue and an end-of-patrol prompt.

### Voice cue style

Patrol mode voice cues focus on opportunities, not turns. The commentary engine (`DrivingContextService`) already produces left/right labels on every block change — patrol mode extends it with two new cue categories:

**Opportunity announcement (immediate free block):**
"Free parking on the right, free until Thursday nine thirty AM."
"Free parking on both sides."
Fires once per block entry when `isFree` returns true for either face. Respects the 8-second minimum gap (same as destination mode AC-DM.19).

**Near-free announcement (free block within 200m but not current block):**
"Free block ahead on your right, one block up."
Fires when the highest-scoring candidate edge within 200m has free parking but the current block does not. This is the "keep going" cue that patrol mode uniquely provides. Fires at most once per 30 seconds to avoid spam.

**Restricted block — stay quiet:**
When the current block is no-parking / restricted on both sides, the app does NOT announce "No parking on left, no parking on right." Silence = keep driving. Voice is reserved for good news (free or metered) and imminent opportunity (free block ahead). This inversion from destination mode is intentional — in patrol mode, the user wants to be alerted only when action is possible.

**Metered block:**
"Metered parking on the right." Announced once per entry (not repeated). Lower priority than free announcements — if a free block is within 200m, the near-free cue takes priority over the metered cue.

**Free-but-restricted-soon:**
"Free on the right, free for thirty more minutes." Fires when `isFree` returns true but restriction starts within 45 minutes. Threshold is 45 minutes (enough lead time to decide whether to commit).

**"Take it?" prompt:**
When a free block enters the 200m radius, the voice cue fires first ("Free parking 200 feet on right, free until 8 PM"). Immediately after the utterance completes, `UIImpactFeedbackGenerator.medium` fires a single haptic pulse. The haptic does not fire during speech — overlapping cues are noisy. No banner card. The voice + haptic combination gives the user a multi-channel signal without requiring eyes on screen.

### End-of-patrol

Three resolution paths:

**1. User finds a spot (explicit, always present):**
The patrol bottom card has a persistent "I found a spot" button (large, thumb-reachable at the bottom). Tapping it exits patrol mode and triggers the W5 pin-drop flow at the current GPS coordinate. This always works regardless of NQ-3 resolution.

**2. Auto-detect parking:**
When `LocationService` reports speed < 2 mph for 10+ consecutive seconds, `PatrolModeService` fires a "Did you find a spot?" prompt — identical mechanic to destination mode's arrival detection (AC-DM.20). "Yes" exits patrol and pins. "No" dismisses the prompt. Auto-detect does not fire if speed drops to 0 for < 8 seconds (red-light filter, same threshold as AC-DM.20). Both paths ship in W8.5.

**3. No free parking found after max radius:**
As described above — end-of-patrol prompt with reason ("No free parking found in this area").

**Note on "continued indefinitely":** Patrol mode does NOT run indefinitely by default. The sweep-budget concept from the PWA (`MAX_METERS = 2500` at `index.html:7083`) translates to the radius-expand approach above, with a hard outer cap at 1,500m. Beyond that, the user is effectively driving out of their intended neighborhood — explicit intervention is correct.

### Park Until filter integration

When Park Until is active (`ContentView.parkUntilTarget != nil`) and the user enters patrol mode:

1. `PatrolModeService.startPatrol(origin:, until: parkUntilTarget)` receives the target time.
2. All `isFree` queries use the full `from: .nowET, until: parkUntilTarget` interval-walk (same as W7.5's binary recolor logic).
3. The patrol bottom card displays a small "Parking until X" pill (same style as W7.5's existing bottom pill) to confirm the filter is active.
4. Free block voice cues include the time context: "Free on the right — safe until your nine PM target."
5. If Park Until is cleared mid-patrol (user taps the clock icon to dismiss it), `PatrolModeService` reverts to the 2-hour default immediately on the next GPS update.

### Patrol mode acceptance criteria (AC-PM.*)

**Entry and target area**
- [ ] **AC-PM.1** A patrol mode entry point is present on the main map screen (toolbar button or Drive Mode sheet toggle per §12 "Entry points"). Tapping enters patrol mode. A visible exit control dismisses it.
- [ ] **AC-PM.2** Patrol mode defaults to the user's current GPS position as the sweep origin. A drop-pin variant allows the user to set an alternate sweep origin.
- [ ] **AC-PM.3** Patrol mode adds `ActiveSheet.patrolMode` to the W5.1 `ActiveSheet` enum. No second `.sheet()` modifier introduced — single-sheet invariant preserved.

**Coverage sweep**
- [ ] **AC-PM.4** `PatrolModeService` ranks candidate streets by `isFree` score (free-block count within candidate edge's block faces) and distance from sweep origin. Higher-scoring streets are suggested first.
- [ ] **AC-PM.5** One-way streets are respected: the service never suggests a street in the wrong direction of travel. (Uses the same directed `streetGraph.adj` as the PWA's `generateParkingRoute`.)
- [ ] **AC-PM.6** Already-driven streets receive a large penalty (-100 × visitCount). The user is not routed back onto a street they have already covered within the same patrol session.
- [ ] **AC-PM.7** When no free blocks remain within the current sweep radius, the radius expands by 200m increments up to 1,500m. If no free blocks are found at 1,500m, a "No free parking found in this area" voice cue fires and an end-of-patrol prompt appears.

**Voice cues**
- [ ] **AC-PM.8** Free block on current street: voice announces "Free parking on the [left/right/both sides], free until [time]" on block entry. Minimum 8-second gap between consecutive announcements.
- [ ] **AC-PM.9** Free block within 200m but not current: voice announces "Free block ahead on your [left/right], one block up" at most once per 30 seconds.
- [ ] **AC-PM.10** No-parking / no-data block: voice stays silent. No "No parking on left" cue in patrol mode.
- [ ] **AC-PM.11** Metered block: voice announces "Metered parking on the [right/left]" at most once per block entry. If a free block is also within 200m, the near-free cue supersedes the metered cue.
- [ ] **AC-PM.11a** When a free block enters the 200m radius, `UIImpactFeedbackGenerator.medium` fires a single haptic pulse after the voice cue utterance completes. The haptic does not fire during speech. No banner card is shown.

**Voice mode toggle**
- [ ] **AC-PM.19** The patrol bottom card has a "Voice mode" toggle icon button. Patrol mode always starts in Commentary mode regardless of prior sessions.
- [ ] **AC-PM.20** Tapping the toggle switches between Commentary and Turn-by-turn. The active mode's icon is tinted with the app accent color; inactive is gray. A 2-second toast ("Switched to turn-by-turn" / "Switched to commentary") confirms the switch. `AVSpeechSynthesizer` speaks the confirmation after any in-flight cue clears.
- [ ] **AC-PM.21** In Turn-by-turn mode, `PatrolModeService` feeds the next sweep waypoint into `RouteService`. A route segment polyline appears on the map. W8.5d approach-escalation fires when the user is within ~100m of the waypoint. On arrival at the waypoint, a new segment is fetched automatically.
- [ ] **AC-PM.22** Switching modes mid-patrol does not reset `visitedBlockKeys` or `coveredEdgeIDs`. Coverage state is preserved across mode switches within a single session.
- [ ] **AC-PM.23** Switching from Turn-by-turn back to Commentary cancels the active route segment fetch (if in-flight) and clears the segment polyline from the map. No crash on cancellation.

**End-of-patrol**
- [ ] **AC-PM.12** A persistent "I found a spot" button on the patrol bottom card exits patrol mode and triggers the W5 pin-drop flow at the current GPS coordinate.
- [ ] **AC-PM.13** Auto-detect: speed < 2 mph for 10+ consecutive seconds surfaces a "Did you find a spot?" prompt. "Yes" exits and pins. "No" dismisses. Prompt does not fire at speed == 0 for < 8 seconds (red-light filter).
- [ ] **AC-PM.14** End-of-patrol clears `PatrolModeService` state: `visitedBlockKeys` and `coveredEdgeIDs` reset on next session start.

**Park Until integration**
- [ ] **AC-PM.15** If Park Until is active when patrol mode starts, `PatrolModeService` passes the `until` time to all `isFree` queries. The patrol bottom card shows the "Parking until X" pill.
- [ ] **AC-PM.16** If Park Until is cleared mid-patrol, the service reverts to 2-hour default on the next GPS update. No crash, no stale target.

**Regression**
- [ ] **AC-PM.17** All destination-mode ACs (AC-DM.1 through AC-DM.28) still pass when patrol mode code is merged.
- [ ] **AC-PM.18** `xcodebuild test` reports all prior tests passing (116/0 minimum, as of W7.5 baseline) plus new patrol mode tests (target: 10+ new cases in `PatrolModeServiceTests.swift`).
