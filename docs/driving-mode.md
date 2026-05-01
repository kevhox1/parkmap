# Driving Mode — Spec

**Status:**
- v1 shipped 2026-04-26, abandoned same day. Black-screen text-card UI lost spatial context; first-user feedback was "this isn't what I had in mind."
- **v2 in flight 2026-04-26.** Map-centric, Google Maps / Waze style.

**Owner:** Kevin (product), Claude (build)

## Why

Real user feedback (2026-04-26): "incredibly difficult to use live in the car." The current full-feature UI is too dense for in-driving use — too many controls, map drifts away from current location, can't tell what street you're on at a glance.

Driving Mode is a **separate full-screen view** optimized for **a phone propped on a dashboard mount** (not CarPlay — that requires native + Apple entitlement, deferred to native iOS phase).

## Scope — v2 ships this

### What the user sees (map IS the screen, like Google Maps / Waze)

```
┌─────────────────────────────────────┐
│  ✕                            🔊    │ ← thin floating top bar
│                                     │   (transparent over map)
│       [LIVE LEAFLET MAP, full       │
│        bleed, auto-follows GPS,     │
│        zoom locked at ~17, streets  │
│        already color-coded by       │
│        parking rules]               │
│                                     │
│             ▲                       │ ← user marker, big blue circle
│           (you)                     │   with arrow pointing in heading
│                                     │
│                                     │
├─────────────────────────────────────┤
│  BOWERY                             │ ← floating bottom card
│  ⬅ Free until Thu 9:30am           │
│  ➡ Metered until 7pm               │
└─────────────────────────────────────┘
```

The map is the existing Leaflet instance — already full-bleed, already
color-codes every street by parking category. Drive Mode just hides
the right-side panel, repositions the user marker, locks zoom + auto-pan,
and floats a top bar + bottom card on top.

### What the user hears (voice synthesis, Web Speech API)

On entering a NEW street (not on every GPS tick):
> *"Bowery. Free parking on the left until Thursday at 9:30. Metered on the right until 7pm."*

If currently on a no-park / no-stand block:
> *"Allen Street. No parking either side."*

If only one side has data:
> *"Mott Street. Free parking on the right until Tuesday 9 AM."*

## Actionable label resolver

The core formatting helper. Given a block face segment + current ET time, return one of:

- `"Free until Thu 9:30am"` — currently safe, restriction kicks in later
- `"Metered until 7pm"` — currently metered, charge ends later
- `"Free until 9am"` — metered, currently free until charge resumes (overnight / Sunday)
- `"No parking"` — currently in a no-parking / no-standing window
- `"No standing"` — special restriction zones
- `null` — segment has no rules / unknown

**Rules:**
- ASP-DONE (>48h until next ASP) → "Free until <day> <time>"
- ASP-soon (≤48h) → "Free until <day> <time>" (same format)
- Metered active now → "Metered until <time>"
- Metered inactive now → "Free until <time>" (where time = next meter resume)
- Active no-parking / no-standing now → "No parking" / "No standing"
- Truck loading active now → "No parking (truck loading)"

We already have `computeNextRestrictionHours()` and `meteredStatusLabel()`. The new `actionableSafetyLabel(seg)` composes them into the formats above.

## Architecture

### Geolocation
- `navigator.geolocation.watchPosition()` with `enableHighAccuracy: true` and `maximumAge: 2000`.
- Fallback if user denies: stay in driving mode but show "Location permission required" instead of street info.

### Current-street detection
- For each GPS update, find the closest segment in `segmentLayers` whose polyline midpoint or projected closest-point is within ~25m.
- Use `getClosestPointOnSegmentGeometry()` (already exists) for projection.
- Group by canonical block (street + from + to) — both sides of the street belong to the same block.
- Find the LEFT and RIGHT side segment for that block via `findSegmentByBlock(street, from, to, side)`.

### LEFT vs RIGHT detection
- We have GPS heading (`navigator.geolocation.position.coords.heading`) when the user is moving.
- Combined with the segment's geometry, compute LEFT/RIGHT relative to the driver's direction of travel.
- For an east-west street: heading-east → LEFT=N, RIGHT=S; heading-west → LEFT=S, RIGHT=N.
- For a north-south street: heading-north → LEFT=W, RIGHT=E; heading-south → LEFT=E, RIGHT=W.
- For diagonal/curvy streets (Broadway), use the segment's bearing at the user's projected position.

### Voice synthesis
- `window.speechSynthesis` + `SpeechSynthesisUtterance`.
- Rate-limit: max one announcement per 30 seconds.
- De-duplicate: don't re-announce the same street + same labels you announced last time.
- Mute toggle in the top bar; persist preference in localStorage.

### Wake lock
- `navigator.wakeLock.request('screen')` on mode entry.
- Release on exit.

### Re-entry / state
- Driving mode entry via a "🚗 Driving Mode" button on the main screen.
- Exit returns to the regular app at last viewport.

## Out of scope for v1

- ❌ Turn-by-turn navigation ("turn right in 200ft")
- ❌ Pre-set "intent" mode ("find ASP-done blocks") — backlog v2
- ❌ "Park here now" auto-detect — backlog v2
- ❌ Voice commands (mic input)
- ❌ Adjusting controls while driving — read-only

## Dependencies on existing code (already there)

- `segmentLayers` — loaded tile data
- `findSegmentByBlock(street, from, to, side)` — side lookup
- `getClosestPointOnSegmentGeometry(seg, lat, lng)` — projection
- `canonicalStreetName(name)` — normalization
- `computeNextRestrictionHours(seg)` — rule resolver
- `meteredStatusLabel(seg)` — metered timing
- `nowET()`, `toETDateStr()` — ET-aware time
- `escapeHtml()` — XSS-safe rendering

## Build order

1. **`actionableSafetyLabel(seg)`** — formatting helper. Pure function, easy to unit-test.
2. **`getDrivingDirectionContext(latlng, heading)`** — given current GPS + heading, return `{ block: {street, from, to}, leftSeg, rightSeg, leftLabel, rightLabel }` or `null`.
3. **Driving Mode UI** — full-screen overlay, color band, big text.
4. **Geolocation + wake-lock + entry/exit wiring.**
5. **Voice synthesis** with rate-limiting + de-dup.
6. **Real-world drive test** — Kevin actually drives somewhere with the phone mounted.

Each step ships independently behind a `?driving-mode` query flag until the whole flow works end-to-end.

## Success criteria

- Kevin (or any user) can hit "🚗 Driving Mode" while driving in Manhattan and:
  - See the current street name big and clear
  - See LEFT side and RIGHT side parking status as actionable labels
  - Hear a voice announcement when transitioning to a new street
  - Trust that the labels are correct (rule resolver matches the static map view)

## End-state (out of v1 scope, but the trajectory)

- v2: pre-set intent (looking for ASP-done) + simple turn suggestion ("try Spring Street next")
- v3: "Park here now" auto-detect when speed = 0 for >10s on a safe block
- Native iOS rewrite: replace `navigator.geolocation` with CoreLocation, `speechSynthesis` with AVSpeechSynthesizer, web map with MapKit. Then apply for CarPlay entitlement.
