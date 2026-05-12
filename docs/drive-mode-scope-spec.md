# Drive Mode — iOS v1.0 Scope Decision

**Status:** Pending Kevin's decision on §0 open questions before dispatch.
**Author:** @tech-lead
**Date:** 2026-05-12
**Supersedes:** Nothing — `docs/drive-mode-routing.md` is the PWA v3 reference and stays as historical context. This spec governs the iOS v1.0 question only.
**Related:** `docs/ios-mvp-spec.md` §2.2 (Drive Mode explicitly out of scope — this spec may change that); `docs/w5-pin-drop-spec.md` §6 (arrival → pin-drop hook intersection).

---

## §0 — Open Questions for Kevin (answer these before code starts)

These are binary. A one-line answer to each is enough.

| # | Question | Options |
|---|---|---|
| OQ-1 | **Which option do you choose?** | A (full PWA port), B (vision-focused), C (Apple Maps backend), D (defer to v1.1) |
| OQ-2 | **Drive-test the PWA before iOS build starts?** | Yes — complete the Manhattan drive test first (1-2 weeks); OR No — build iOS in parallel with drive-test, accept that the design may need revision mid-build |
| OQ-3 | **Routing provider if Option B or C is chosen.** | Mapbox HTTP-only (no iOS SDK, ~$0 at TestFlight scale); OR Apple MKDirections (free, no guaranteed alternatives); OR Hybrid (MKDirections for route, Mapbox HTTP for alternatives scoring only) |
| OQ-4 | **Is parking-aware route selection (scoring routes by parking exposure) required in v1.0?** | Yes — the scoring is the differentiator; OR No — a single best-effort route is fine, parking commentary on top is enough |
| OQ-5 | **TestFlight timeline.** Does Drive Mode ship in TF1 (same build as pin drop / notifications / ASP banner), or TF2 (a follow-up build 3-6 weeks after TF1)? | TF1 (block pin drop from going to TestFlight until Drive Mode is ready); OR TF2 (ship pin-drop MVP to TestFlight now, drive mode follows) |

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

## §2 — Options Evaluated

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

## §3 — Recommendation

**Recommended option: Option E — ship TF1 without Drive Mode, ship Option B Drive Mode in TF2.**

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
- The existing Mapbox token in `tracker-config.js` (`pk.*` token, URL-restricted to `kevhox1.github.io` and `localhost:8765`) cannot be reused for iOS native HTTP calls — the iOS app's requests will not come from those URLs. A new Mapbox token will need to be created for the iOS bundle, restricted to the app's bundle ID via Mapbox's iOS SDK token restriction (or left as an unrestricted token with API-key access stored in a `.xcconfig` file outside version control). **This is a 5-minute Mapbox dashboard task, but it must happen before Drive Mode code starts.**
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

### Sequencing (Option E recommendation)

```
[NOW]      W5 (pin drop)      → W6 (notifications)    → W7 (ASP banner)  → W7.5 (Park Until X)
                                                                            ↓
                                                               TF1 BUILD (W8) — TestFlight ships
                                                                            ↓
                                                               Kevin drive-tests PWA (parallel)
                                                                            ↓
                                                               Drive-test findings reviewed
                                                                            ↓
[TF2]      W8.5 (Drive Mode Option B — see streams below)
                                                                            ↓
                                                               W9 (TF2 build)
```

### Drive Mode work streams (Option B, labeled W8.5)

**All streams below depend on W7.5 being merged and the drive-test findings being reviewed.**

| Stream | Owner | Parallelizable? | Est. sessions | Notes |
|---|---|---|---|---|
| **W8.5a** — CoreLocation drive session: `CLLocationManager` heading updates, `startUpdatingLocation` in drive mode, heading-up `MKMapView` rotation, follow-mode with recenter button, wake lock | @ios-engineer | Yes — no UI dependency | 1.5 | Port of PWA `stabilizedHeading`, `setDrivingMapRotation`, `recenterDriveMode`. `MapViewRepresentable` changes. |
| **W8.5b** — Destination input + routing: `MKLocalSearchCompleter`-backed search UI, route fetch (MKDirections or Mapbox HTTP per OQ-3), route polyline rendered on map, destination pin, recent destinations in `UserDefaults` | @ios-engineer | Yes — parallel with 8.5a (different files) | 2 | New file `Views/DriveModeDestinationView.swift`. New file `Services/RouteService.swift`. |
| **W8.5c** — Parking commentary engine: `getCurrentDrivingContext` port, side-of-street labels on bottom card, `AVSpeechSynthesizer` voice, block-change detection, `AVAudioSession` configuration, voice mute toggle | @ios-engineer | Serializes after W8.5a (needs heading data) | 2 | Port of `getCurrentDrivingContext`, `speakDrivingContext`, `renderDrivingContext` from PWA. New file `Services/DrivingContextService.swift`. New file `Views/DriveModeBottomCard.swift`. |
| **W8.5d** — Final approach escalation + arrival: 500m threshold detection, elevated voice frequency in approach zone, "Approaching destination" visual strip, arrival prompt → W5 pin-drop hook | @ios-engineer | Serializes after W8.5b + W8.5c | 1 | New, not in PWA. Requires destination coordinate from W8.5b and commentary engine from W8.5c. |
| **W8.5e** — Parking-aware route scoring (ONLY if OQ-4 = yes) | @ios-engineer | Serializes after W8.5b | 0.5–1 | Port of `pickBestParkingAwareRoute` (~40 lines). Skip entirely if OQ-4 = no. |
| **W8.5 QA** | @qa-verifier | After all streams merge | 1.5 | Simulator + real-device GPS (requires Apple Dev approval already obtained by TF1 milestone). Drive-mode-specific AC verification. |
| **W8.5 Design** | @designer | Can review W8.5c/d in parallel | 0.5 | Bottom card layout, approach strip, font sizing for in-car readability. |

**Parallel streams:** W8.5a and W8.5b can be dispatched simultaneously (they touch different files: `MapViewRepresentable.swift` for 8.5a vs. new destination UI files for 8.5b). W8.5c serializes after W8.5a (it needs `CLHeading` from the location manager). W8.5d serializes after both W8.5b and W8.5c.

**Total W8.5 estimate:** 7–8 sessions across 2-3 `@ios-engineer` threads (with parallelism). Calendar time: ~2-3 weeks with parallel execution. Add 1 QA session = 3-4 weeks total for TF2.

### W7.5 / Drive Mode overlap

The "Park Until X" filter (`W7.5`) and Drive Mode share one integration: the arrival flow. When Drive Mode detects arrival and triggers the W5 pin-drop, the W7.5 prompt ("Parking until when?") fires naturally from `ParkPinService.pinDropped`. No additional wiring needed — W5's existing `pinDropped` event covers this.

There is a potential visual conflict: W7.5's Park Until filter colors blocks by the user's departure time, while Drive Mode's bottom card shows real-time status. The simplest resolution: Drive Mode always shows real-time status (ignores the Park Until filter while in Drive Mode). This preserves clarity for the driver. The Park Until filter remains active on the static map view for pre-drive browsing. This decision can be confirmed in the W8.5 spec.

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

- `HANDOFF.md` §"Drive-test pending" — the drive-test this spec depends on.
- `HANDOFF.md` §"Phase 5 progress" — W5/W6/W7/W7.5 must ship before W8.5 starts (Option E sequencing).
- `docs/ios-mvp-spec.md` §2.2 — Drive Mode is currently explicitly out of scope. If Kevin picks Options A/B/C, that line is superseded by this spec. Do not edit the mvp-spec directly; this spec is the override.
- `docs/drive-mode-routing.md` — PWA v3 reference spec. Read before starting W8.5b (routing). Not binding for iOS v1.0 scope decisions, but the architecture section (§Architecture, §Data flow) is a useful reference for the Swift port.
- `docs/w5-pin-drop-spec.md` §6.2 — the `pinDropped` hook that Drive Mode's arrival flow (AC-DM.20) will trigger.
- `docs/ios-color-threshold-spec.md` §8 — W7.5 "Park Until X" overlap with Drive Mode (§7 of this spec).
