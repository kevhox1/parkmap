# WePark iOS MVP — TestFlight build

**Status:** Draft, awaiting Kevin's sign-off on the open decisions in §3.
**Owner:** @ios-engineer (build), Tech Lead (spec).
**Distribution target:** TestFlight (internal).
**Source PWA:** `https://kevhox1.github.io/parkmap/` (stays live in maintenance mode while this is built).

This spec is the contract for the first Swift+SwiftUI build of WePark. It is
deliberately the thinnest useful slice of the existing PWA — enough to validate
the native UX, satisfy App Store review, and put a real binary in real users'
hands. Drive Mode, community, threat tracker, and route planning are explicitly
out of scope (§2.2) and will land in later phases.

---

## 1. Problem & user story

A NYC street parker opens their phone after parking the car and wants two things:

1. **"Where did I park, and when do I have to move it?"** — a pin on a map of
   their block, with an unambiguous label like *"Free until Thu 9:30am"* and a
   notification that fires before that time.
2. **"Is today's ASP suspended?"** — a one-glance answer that saves them a trip
   to the NYC DOT Twitter/X feed.

The PWA at `https://kevhox1.github.io/parkmap/` already does both, but it lives
in Safari, can't deliver reliable local notifications on iOS (Web Push on iOS
PWA requires installation to home screen and is unreliable in practice), and
doesn't feel like a parking app — it feels like a website. The native build
fixes the notification reliability problem and earns a place on the user's home
screen.

The MVP user story this spec covers, end-to-end:

> *I open WePark. I see Manhattan with the parking blocks color-coded. I scroll
> to where my car is, tap the block, see "Free until Thu 9:30am". I hit "Park
> here". The app drops a pin and asks for notification permission with a clear
> rationale. I close the app. Wednesday at 8:30pm I get a local notification
> that says "Move your car — restriction starts at 9:30am tomorrow." If
> Thursday turns out to be in the ASP suspension calendar, the notification is
> skipped and the app banner says "ASP suspended today."*

That's the whole MVP. Everything else is later.

---

## 2. Scope

### 2.1 In scope

- **Map of Manhattan** with the existing 1,028 tile JSONs in `tiles/` rendered
  as colored polylines per block face. Color = parking category. Match the PWA
  palette exactly (see §6 for hex values from `CATEGORIES` in `index.html`:1558).
- **Color-coded blocks.** Polyline color tracks `dominantCategory` from each
  segment (or `mostRestrictiveCategory(rules)` if absent). Same scheme as PWA:
  green (free), yellow/orange (metered/ASP), red (no parking/no standing),
  grey (unknown).
- **Tap a block → block detail sheet.** Sheet shows the actionable safety
  label ("Free until Thu 9:30am") plus the underlying rules list. The label is
  produced by a Swift port of `actionableSafetyLabel` (`index.html`:5457).
- **"Park here" flow.** Long-press OR tap-block → "Park here" button in the
  block sheet. Drops a "My Car" pin at the tapped lat/lng (NOT snapped to the
  segment — see §6 / 2026-04-22 changelog entry, snapping was explicitly
  removed in the PWA after corner-detection ambiguity broke trust).
- **Persistence.** "My Car" pin saved to `UserDefaults` with the snapshot of
  the detected block (street/from/to/side) and the parked-at timestamp.
  Survives app relaunch.
- **Local "move your car" notification** scheduled via
  `UNUserNotificationCenter` when a pin is dropped on an ASP-restricted block.
  Fire time = (next ASP start - 1 hour), computed via the Swift port of
  `computeNextRestrictionHours` (`index.html`:5315) and skipping dates in the
  ASP suspension calendar.
- **ASP suspension banner** at the top of the map. Three states (mirroring the
  PWA's `renderASPStatusBanner` at `index.html`:2093):
  - Today suspended → red banner with reason.
  - Tomorrow suspended → yellow banner.
  - Otherwise → small green "ASP active today" confirmation.
- **Mute toggle for notifications** (mirrors the PWA's `🔊/🔇` Drive Mode
  pattern; persisted in `UserDefaults`).

### 2.2 Out of scope (deferred — do NOT build)

- **Drive Mode.** Turn-by-turn, voice, heading-up rotation, parking-aware route
  selection, side-of-street green highlights. The biggest deferred scope. Will
  be its own multi-week effort post-MVP.
- **Smart Score / Top Blocks / route planner / "Find Parking Near Me."**
- **Auth + Supabase + zone chat.** No backend in MVP.
- **Threat tracker** (sweeper / ticket agent / block cleaned reports).
- **APNs push notifications** (server-side). MVP is local-only.
- **Address search / Mapbox Search Box.**
- **Smart Move recommendations** (i.e., "move tonight to Elizabeth St, skip
  tomorrow's ASP"). Only the local pin's block is considered.
- **iPad layout, watchOS, CarPlay.**
- **Snow emergency (NYC 311 API).** Static suspension calendar only.
- **Cross-pollination** between tracker and chat.

If something seems useful but isn't on the In list, it's Out. Push it to the
`Out-of-scope follow-ups` section (§8) instead of building it.

---

## 3. Open decisions (Kevin to confirm before any code starts)

These need a yes/no from Kevin. Listed in the order he should resolve them.
Each has a recommendation, but the recommendation is not a decision — Kevin
picks.

### 3.1 Mapbox iOS SDK vs Apple MapKit  *(blocking — affects everything)*

- **Trade-off.** Mapbox iOS SDK gives parity with the PWA's existing Mapbox
  navigation-day-v1 styling (already shipped at `index.html`:1591) and
  preserves the Drive Mode investment for when we port it. It is paid above
  the free monthly tier (50k MAU free, then ~$5/k). MapKit is native, free,
  visually polished by default, but has fewer customization knobs and would
  require us to re-style for Drive Mode parity later.
- **Recommendation.** Mapbox iOS SDK. The Drive Mode experience is the long-
  term moat (per `HANDOFF.md`:18, "the biggest active investment") and we
  don't want to rebuild it twice. MAU costs are negligible at TestFlight
  scale.
- **Risk if MapKit is picked instead.** The Drive Mode port has to do its own
  custom styling on MapKit, which Apple's docs allow but are limited around.
  Side-of-street polyline highlighting, route polyline rendering, and
  heading-up rotation are all doable on MapKit but not free.
- **Open research item for the engineer either way.** Confirm whether the
  chosen SDK can render ~12k–40k polylines from in-memory GeoJSON without
  frame drops on an iPhone 12. Mapbox's vector-tile + custom-source approach
  should handle it; MapKit's `MKMultiPolyline` is less battle-tested at this
  density.

### 3.2 App bundle identifier  *(blocking — affects App Store Connect setup)*

- **Trade-off.** Bundle ID is permanent once published.
- **Recommendation.** `com.kevinhoxha.wepark`. Personal-domain reverse-DNS,
  consistent with the GitHub username (`kevhox1`), product name `wepark`.
  Avoids `parkmap` (which is the repo name but not the product name).
- **Alternates.** `nyc.wepark.app`, `com.wepark.ios` (would need domain
  ownership of `wepark.com` / `wepark.app`).

### 3.3 Tile bundling  *(blocking — affects app size + offline UX)*

- **Trade-off.** Bundling all 1,028 tile JSONs into the app means the map
  works fully offline (great UX in subway / dead zones) and the data is
  versioned with the binary (no stale-cache bugs). Cost: increases the IPA by
  ~6–8 MB compressed (raw is ~27 MB on disk; tile JSONs compress well — text
  with repetition). Lazy-loading from a CDN is smaller, but requires
  connectivity for first paint and brings back the SW-cache-versioning class
  of bugs the PWA still has.
- **Recommendation.** **Bundle.** Tile data is static and refreshes ~quarterly
  with NYC DOT data. The IPA size hit is acceptable — TestFlight size limit
  is 4 GB; we're nowhere near it. Update path: ship a new app version when
  the tile data refreshes (same cadence as PWA today, just a different
  delivery mechanism).
- **Note for engineer.** Copy `tiles/index.json` and `tiles/tile_*.json`
  verbatim into `Resources/`. Don't re-encode — the JSON shape is the
  contract. (See `HANDOFF.md`:96: "Don't regenerate unless Kevin has changed
  upstream NYC source data.")
- **Discrepancy to flag to Kevin.** `HANDOFF.md` says "976 tile JSONs (~6.39
  MB)" but the actual `tiles/index.json` reports `totalTiles: 1028,
  totalSegments: 40664`, and `du -sh tiles/` returns 27 MB on disk. Likely
  the 6.39 MB was a gzipped-over-the-wire number from an older snapshot.
  Confirm before sizing the bundle.

### 3.4 Local-notification permission timing  *(blocking — affects App Store review)*

- **Trade-off.** Asking up front on first launch is the simplest code path
  but App Store reviewers and savvy users see it as a poor-UX dark pattern.
  Asking on first pin drop is more contextual ("you parked your car, want a
  reminder?") and aligns with Apple's HIG, but adds a code branch.
- **Recommendation.** **Ask on first pin drop.** Use a simple in-app
  rationale sheet ("WePark uses a notification to remind you to move your car
  before alternate-side parking starts. We never send marketing
  notifications.") immediately before the system prompt. If the user denies,
  the pin still drops; we just show a one-time inline message that the
  reminder was skipped.
- **Location permission** (separate prompt) — same pattern: ask the first
  time the user taps the "center on me" button, not on launch.

### 3.5 Minimum iOS version  *(blocking — affects SwiftUI APIs and Mapbox SDK)*

- **Recommendation.** **iOS 17.** Reasons:
  - SwiftUI `@Observable` macro (cleaner than `ObservableObject`) needs 17.
  - Mapbox iOS SDK v11 (current) requires iOS 14+ and works cleanly on 17.
  - iOS 17 adoption is >85% as of 2026-05; the long tail isn't worth the
    SwiftUI tax.
- **Alternate.** iOS 16 if Kevin has a personal device on 16. Costs
  ~10% more boilerplate for state management.

### 3.6 `Info.plist` privacy strings  *(blocking — App Store review will reject without these)*

Concrete copy proposals:

- **`NSLocationWhenInUseUsageDescription`** —
  *"WePark uses your location to center the map on your block and recommend
  parking nearby. Your location is never sent off your device."*
- **Notification rationale (in-app sheet, before system prompt)** —
  *"Get a reminder before alternate-side parking starts so you never get
  ticketed. Notifications are scheduled on-device only."*

Kevin: confirm the wording is a fair description of the actual MVP behavior.

### 3.7 Color match for parking categories  *(non-blocking — but lock the answer before pixel-pushing starts)*

- **Trade-off.** Port the PWA's exact hex values (consistency, fewer surprises
  for users coming from the PWA) vs adopt iOS system semantic colors
  (`Color.red`, `Color.yellow`) for automatic Dark Mode handling.
- **Recommendation.** **PWA hex for MVP.** Dark Mode polish is later. The
  exact values are in `CATEGORIES` at `index.html`:1558 — copy them verbatim
  into a Swift `ParkingColors` enum.

| Category | Hex | Meaning |
|---|---|---|
| `ASP_MON_THU` | `#8b5cf6` | Mon/Thu street cleaning |
| `ASP_TUE_FRI` | `#f97316` | Tue/Fri street cleaning |
| `ASP_OVERNIGHT_MWF` | `#ec4899` | Overnight Mon/Wed/Fri |
| `ASP_OVERNIGHT_TTHS` | `#06b6d4` | Overnight Tue/Thu/Sat |
| `ASP_DAILY` | `#eab308` | Daily street cleaning |
| `METERED` | `#3b82f6` | Metered |
| `TRUCK_LOADING` | `#92400e` | Truck loading zone |
| `NO_PARKING` | `#ef4444` | No parking |
| `NO_STANDING` | `#7f1d1d` | No standing/stopping |
| `SPECIAL` | `#1f2937` | Special restriction |
| `FREE` | `#22c55e` | Free parking |
| `UNKNOWN` | `#d1d5db` | Unknown / no data |

---

## 4. Architecture

### 4.1 High-level data flow

```
App launch
  → Load bundled `tiles/index.json` and `asp-2026.json` synchronously
  → Mount MapView centered on Manhattan (40.7831, -73.9712 — same as PWA)
  → Lazy-load visible tiles into TileLoader (decode JSON, hand polylines + rules to MapView)
  → ASPBanner reads ASPSuspension service for today/tomorrow

User taps a block
  → MapView resolves the tap to the closest Segment (point-to-polyline distance)
  → BlockDetailSheet presents Segment + actionableSafetyLabel(seg) result

User taps "Park here"
  → ParkPinService persists ParkedCar(lat, lng, segmentSnapshot, parkedAt) to UserDefaults
  → If notification permission not yet granted: show rationale sheet → request → on grant:
  → NotificationScheduler.schedule(for: parkedCar) using ParkingRulesEngine.nextRestriction(seg)
```

No network calls in MVP. No async backend. The whole app is offline-first.

### 4.2 Module layout (`ios/WePark/`)

This is a sketch; the iOS Engineer owns the final Xcode project structure. Don't
take this as prescriptive beyond the boundaries between modules.

```
ios/WePark/
  WeParkApp.swift                    # @main, app entry, root scene
  Models/
    Segment.swift                    # Mirrors tile JSON shape (id, street, from, to, side, line, rules, dominantCategory)
    ParkingRule.swift                # category, days, timeRanges, anytime, arrow
    Category.swift                   # enum: ASP_MON_THU, METERED, NO_PARKING, ... + label + color
    ParkedCar.swift                  # lat, lng, segmentSnapshot, parkedAt
    ASPSuspension.swift              # date (yyyy-MM-dd ET), reason
    SafetyLabel.swift                # text + severity (free | metered | restricted | unknown)
    NextRestriction.swift            # hours, label, category?, rule?
  Views/
    MapView.swift                    # SwiftUI wrapper around Mapbox or MapKit
    BlockDetailSheet.swift           # rules list + safety label + "Park here" button
    ParkPinSheet.swift               # confirm + side-picker (when ambiguous) + drop pin
    ASPBanner.swift                  # red/yellow/green banner reading ASPSuspensionService
    SettingsSheet.swift              # mute toggle + version info
  Services/
    TileLoader.swift                 # loads bundled tile_R_C.json on demand for visible bounds
    ParkingRulesEngine.swift         # the rules port — see §4.3
    ASPSuspensionService.swift       # today/tomorrow lookup; loads asp-2026.json once
    NotificationScheduler.swift      # UNUserNotificationCenter wrapper; idempotent reschedule
    ParkPinService.swift             # UserDefaults read/write + segment-snapshot resolution
    StreetNameNormalizer.swift       # canonicalStreetName port
  Resources/
    tiles/index.json                 # copied verbatim from repo root /tiles/
    tiles/tile_*.json                # 1,028 files
    asp-2026.json                    # extracted from ASP_SUSPENSIONS_2026 (see §4.4)
```

### 4.3 ParkingRulesEngine — the port from JS

The Swift port of the rules engine is the highest-risk module because its
output is the user-facing contract. The PWA labels are the source of truth; the
iOS app must produce **byte-identical** label strings for the same inputs.

Functions to port from `index.html` (line numbers as of `689d089`):

| JS function | Line | Swift equivalent |
|---|---|---|
| `actionableSafetyLabel(seg)` | 5457 | `ParkingRulesEngine.safetyLabel(for: Segment) -> SafetyLabel` |
| `computeNextRestrictionHours(seg)` | 5315 | `ParkingRulesEngine.nextRestriction(for: Segment) -> NextRestriction` |
| `computeHoursUntilASP(cat, rule, ...)` | 3911 | private helper, walks 14-day window, skips `isASPSuspended` dates |
| `computeHoursUntilActive(rule, ...)` | 3809 | private helper for non-ASP rules |
| `meteredStatusLabel(seg)` | 5378 | `ParkingRulesEngine.meteredStatus(for: Segment) -> String` |
| `isASPCategory(cat)` | 1700 | `Category.isASP` |
| `isASPDayForCategory(cat, dayOfWeek)` | 1689 | `Category.isASPDay(_ dayOfWeek: Int)` |
| `isScheduleActiveAt(rule, ...)` | 1705 | `ParkingRule.isActive(at:)` |
| `getNextRestrictionTimeLabel(hours)` | 5429 | private formatter, "Today/Tomorrow/<weekday> <H:MM><am/pm>" |
| `canonicalStreetName(raw)` | 1777 | `StreetNameNormalizer.canonical(_ raw: String) -> String` |
| `mostRestrictiveCategory(rules)` | 2141 | `ParkingRulesEngine.dominantCategory(rules:)` |
| `isASPSuspended(dateStr)` | 2135 | `ASPSuspensionService.isSuspended(_ date: Date) -> Bool` |
| `nowET()` | 1668 | `Date.nowET` (TimeZone "America/New_York") |
| `toETDateStr(d)` | 1671 | helper, `yyyy-MM-dd` in ET |

**Critical correctness requirement.** All time math is in **America/New_York**
TZ, not the device TZ. The PWA is explicit about this (`nowET()` everywhere)
because a user in California opening the app to check NYC parking still wants
NYC-time answers. Use `TimeZone(identifier: "America/New_York")!` and
`Calendar(identifier: .gregorian)` with that TZ set.

**Output contract.** Run a manual sanity check before sign-off: for ~10 sample
segments at the same wall-clock time, the Swift `safetyLabel(...).text` must
exactly equal the JS `actionableSafetyLabel(...).text` for the same input.
Strings like `"Free until Thu 9:30am"` are character-for-character significant.
See acceptance criterion AC-3 in §6.

### 4.4 ASP suspension calendar — extract to data

The PWA holds the calendar as a JS object literal at `index.html`:2030
(`ASP_SUSPENSIONS_2026`, 41 dates). For iOS, propose extracting it to
`ios/WePark/Resources/asp-2026.json`:

```json
{
  "year": 2026,
  "dates": [
    { "date": "2026-01-01", "reason": "New Year's Day" },
    { "date": "2026-01-06", "reason": "Three Kings' Day" },
    ...
  ]
}
```

This decouples the data refresh path from code (annual update is a JSON edit,
not a Swift edit) and matches the future shape we'll get when NYC 311 API gets
wired post-MVP. The 41 dates are listed in full at `index.html`:2030–2073.

### 4.5 What's intentionally absent

- **No backend.** No Supabase. No auth. Don't import a networking lib.
- **No analytics SDK.** TestFlight gives us crash reports for free; that's
  enough for the MVP.
- **No feature flags.** The MVP is small enough that flags add complexity
  without value.

---

## 5. Work streams

The MVP is small enough to be largely owned by one engineer. Streams are still
worth calling out so dependencies are visible.

### W1 — Project bootstrap *(blocks everything; no parallelism)*

- New Xcode project, bundle ID, signing, TestFlight provisioning profile.
- Target iOS 17, Swift 5.9+, SwiftUI lifecycle.
- `Info.plist` privacy strings (§3.6).
- Owner: @ios-engineer. Depends on: Kevin's Apple Developer enrollment
  finishing (§3 prerequisite).

### W2 — Models + tile loading + map render *(parallel with W3 once W1 done)*

- Define `Segment`, `ParkingRule`, `Category`, etc. matching the tile JSON shape.
- `TileLoader` reads bundled `tiles/index.json`, lazily decodes the
  `tile_R_C.json` for visible map bounds (port `getTilesForBounds` from
  `index.html`:2221).
- `MapView` renders polylines colored by `dominantCategory`.
- Owner: @ios-engineer.

### W3 — ParkingRulesEngine port *(parallel with W2)*

- The port described in §4.3. Pure-logic module, no UI dependency.
- Unit-testable with sample segments. Recommend writing a parity test that
  loads ~20 known-input segments + the same wall-clock time and asserts the
  Swift output equals a snapshot of the JS output.
- Owner: @ios-engineer. Could be split off to a second engineer if available
  but isn't necessary for MVP.

### W4 — Block detail sheet *(depends on W2 + W3)*

- Tapping a polyline opens `BlockDetailSheet` with the safety label + rules.
- Wire to `ParkingRulesEngine`.
- Owner: @ios-engineer.

### W5 — Pin drop + persistence *(depends on W4)*

- `ParkPinService` (UserDefaults) + `ParkPinSheet` UI for confirm + side picker
  (when ambiguous). Mirror PWA behavior: pin stays at the tapped location, NOT
  snapped to the segment.
- Owner: @ios-engineer.

### W6 — Notifications + permission flow *(depends on W3 + W5)*

- `NotificationScheduler` schedules a single `UNTimeIntervalNotificationTrigger`
  at (next-restriction - 1h), respecting suspension calendar.
- Permission rationale sheet on first pin drop (§3.4).
- Mute toggle in settings; persisted in UserDefaults; checked at scheduling
  time.
- Owner: @ios-engineer.

### W7 — ASP banner + settings *(parallel; small)*

- `ASPBanner` view with the three-state logic.
- `SettingsSheet` with mute toggle, version, attribution links.
- Owner: @ios-engineer.

### W8 — TestFlight build + smoke *(depends on W1-W7)*

- Archive, upload to App Store Connect, submit to TestFlight internal testers.
- Smoke checklist = §6 acceptance criteria run on a real device.
- Owner: @ios-engineer. Kevin runs the on-device smoke as the first internal
  tester.

**Backend/data work.** None for the MVP. Confirmed: no Supabase, no APNs, no
NYC 311 proxy. The bundled tile JSONs and bundled `asp-2026.json` are the only
data dependencies, both already at HEAD in this repo.
**@backend-data is not on the critical path for this spec.**

**Suggested order.** W1 → (W2 ‖ W3) → W4 → W5 → (W6 ‖ W7) → W8.

**Rough sizing.** With Kevin solo and ramping on Swift, this is plausibly a
3–5 week build to a TestFlight-able binary. Don't hold him to a number —
surface blockers (especially around §3.1 SDK choice and Mapbox SDK
integration) early.

---

## 6. Acceptance criteria

Each item is a checkbox the iOS Engineer (or a QA pass) runs on a real device
before TestFlight submission. *AC-3* and *AC-5* are the high-risk ones.

- [ ] **AC-1** App launches in <2s on iPhone 12 to a Manhattan-centered map.
      All visible blocks color-coded per the `CATEGORIES` palette (§3.7).
- [ ] **AC-2** Map pans + zooms smoothly (60fps target) at zoom 14–18 over
      Manhattan with all visible tiles loaded.
- [ ] **AC-3** **Label parity.** Tap 10 sample blocks at a fixed wall-clock
      time; the popup label string equals the PWA's `actionableSafetyLabel`
      output character-for-character. Sample includes at least: a `FREE`
      block, an `ASP_MON_THU` block (currently free), an `ASP_DAILY` active-
      now block, a `METERED` paid-now block, a `METERED` free-now block, a
      `NO_STANDING` block, a `NO_PARKING` active-now block, a block with
      tomorrow's restriction, and a block whose next restriction crosses a
      suspended date (must skip).
- [ ] **AC-4** Tap green block → "Free until [day] [time]" using the
      "Today / Tomorrow / <Weekday>" format from `getNextRestrictionTimeLabel`
      (`index.html`:5429).
- [ ] **AC-5** **ASP-suspension respect.** When today is in
      `asp-2026.json`: (a) banner shows the suspension state with reason,
      (b) `ParkingRulesEngine.nextRestriction(...)` does not return today's
      ASP as `hours: 0`, (c) any same-day notification is skipped.
- [ ] **AC-6** Tap red block (`NO_PARKING` active) → "No parking" or
      `"No parking (truck loading)"` matching JS line 5469.
- [ ] **AC-7** "Park here" → confirmation sheet → pin drops at the tapped
      lat/lng (NOT snapped). Killing and reopening the app shows the pin in
      the same place.
- [ ] **AC-8** First-time pin drop on an ASP block triggers the notification
      rationale sheet → on grant, schedules a `UNNotificationRequest` for
      (next-ASP-start − 1 hour). Verify with a future-dated test pin.
- [ ] **AC-9** When today is in the suspension calendar AND the user is parked
      on an ASP block whose only same-day restriction is the suspended one,
      no notification fires. (Use a debug pin set for "today" to verify.)
- [ ] **AC-10** Banner: today suspended → red w/ reason (`#fef2f2 / #991b1b`,
      `index.html`:2107). Tomorrow suspended → yellow. Otherwise → small
      green confirmation.
- [ ] **AC-11** Map and rules engine work fully **offline** — Airplane mode
      enabled, app launched cold, every In-scope feature works (tile data,
      block tap, pin drop, label, banner). Notification scheduling works
      offline (it's local).
- [ ] **AC-12** First call to "center on me" prompts for location permission
      with the §3.6 string. Denial does not crash; map stays at the default
      Manhattan center.
- [ ] **AC-13** Mute toggle in Settings disables future notification scheduling
      (existing scheduled notifications are also canceled). Persisted across
      app relaunch.
- [ ] **AC-14** No regressions: Long-press on a non-block area of the map is a
      no-op. Tapping outside any polyline dismisses the open block sheet.
- [ ] **AC-15** App icon, launch screen, and splash branding present (no
      placeholder Xcode default).

---

## 7. Risks & open research items (engineer should investigate during W1/W2)

These aren't blocking decisions for Kevin — they're things the iOS Engineer
should resolve early in the build because they could move scope.

- **R1.** Can Mapbox iOS SDK render ~12,560 polylines (the Manhattan tile
  segments at full coverage) without dropped frames at zoom 16? If not, the
  fallback is to clip to the visible viewport (the PWA does this implicitly
  via `loadVisibleTiles` at `index.html`:3456) — port that pattern.
- **R2.** `computeNextRestrictionHours` 14-day walker has an edge case at
  week boundaries that hasn't been independently audited — when a rule's
  `timeRanges` is empty AND `offset === 0` AND `now` is mid-day on a
  matching ASP day, the JS returns `0` (active) but the surrounding
  conditional flow is dense. Engineer: when porting, write a parity test
  with at least 5 boundary cases (Saturday → Sunday rollover, end-of-month,
  start-of-year, suspended-day adjacent to non-suspended-day, midnight ET
  exactly). Surface any deltas to Kevin before sign-off.
- **R3.** **The HANDOFF.md tile-count mismatch flagged in §3.3** —
  `HANDOFF.md` says 976 tiles / 6.39 MB, actual is 1,028 tiles / 27 MB
  on disk. Engineer should run `du -sh tiles/` themselves before sizing the
  app bundle; 6.39 MB might be a stale post-gzip wire size from an earlier
  snapshot.
- **R4.** Mapbox SDK token strategy. The PWA ships a `pk.*` token in
  `tracker-config.js` URL-restricted to `kevhox1.github.io` + `localhost`.
  For iOS, Mapbox supports per-app **secret** tokens (`sk.*`) for SDK
  downloads and per-app **public** tokens for runtime. We need a separate
  iOS-restricted token, NOT to reuse the web one. Engineer: create a new
  Mapbox token scoped to the iOS bundle ID before W1 ships.
- **R5.** Permission denied edge cases. If the user denies notifications, we
  fall back to "no reminders" silently. If they deny then re-enable in iOS
  Settings, the next pin drop should reschedule — verify
  `UNUserNotificationCenter.current().getNotificationSettings()` is checked
  on every pin drop, not cached at app launch.
- **R6.** Time-zone edge case on user travel. If a user parks in NYC then
  flies to LA, the device clock changes but `nowET()` is the right reference
  for "when does ASP start." Confirm the notification scheduler uses
  absolute Unix time (computed via the ET calendar) so the notification
  fires at the correct NYC moment regardless of where the device is.

---

## 8. Out-of-scope follow-ups

Captured here so they don't get lost. Each becomes a candidate for a Phase 5b
spec doc once MVP ships.

- **Drive Mode port** (Mapbox-based heading-up rotation, voice, route
  selection). Biggest deferred chunk; likely its own multi-week phase.
- **Smart Move recommendation engine.** "Move tonight to Elizabeth St,
  skip tomorrow's ASP." See `PRODUCT.md`:76.
- **Address search.** Mapbox Search Box already integrated in the PWA
  (`HANDOFF.md`:99); port is straightforward but out of MVP scope.
- **Threat tracker UI.** Sweeper / ticket-agent / block-cleaned reports.
  Requires Supabase tracker schema applied (`HANDOFF.md`:36, currently
  pending). Defer until backend lands.
- **Zone chat.** Same backend-pending dependency.
- **Auth (email magic-link)** — only needed once chat or tracker land.
- **APNs** for push notifications. Server-side; needed only when tracker
  /chat introduce real-time updates worth pushing.
- **Snow emergency / NYC 311 API.** No CORS in native, so this becomes
  trivially achievable once we have a `URLSession` call. Spec note in
  `HANDOFF.md`:61.
- **2027 ASP calendar refresh.** Annual data update; trivial JSON edit
  once the new calendar PDF drops. Calendar is `asp-2026.json`; rename
  + extend.
- **iPad layout / CarPlay / watchOS.** Each is a real product surface, none
  is the MVP.
- **Dark Mode polish.** PWA hex colors aren't tuned for Dark Mode; revisit
  with semantic system colors once we have the shape locked.
- **App-launch onboarding** ("welcome to WePark, here's the dot, here's
  your block"). Not necessary for TestFlight internal-tester audience.
- **Crash-free rate / lightweight in-app QA telemetry.** TestFlight crash
  reports cover MVP; revisit if we ever want Sentry/PostHog post-public
  launch.
