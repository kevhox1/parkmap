# R35: map polish and trip destination (from Kevin's build 35 phone review)

Source: `docs/field-testing-log.md`, section "2026-11-27 (evening) - Build 35 phone review", items R35-1 to R35-4 and F-1. R35-5 (test reminder) and F-2 (Parking Hunt) are not covered here.
Owner: `@ios-engineer`. Backend, PWA: no work. `@designer`: optional review of PR2 line widths and PR5 planner row (no new art needed).
Screenshots (Kevin, 10:02 to 10:05 PM, Penn Station): `/Users/kevinhoxha/.claude/uploads/f8d5a3ca-5371-4933-9534-79989e164bb8/` files `0fed2819-image.png` (search card gap, thick salmon blocks), `42544b97-image.png` (Locate at building level), `d1490e9f-image.png` (red blanket at neighborhood zoom; "until 1:04 AM" at 10:05 PM).

Everything is Stoop-only, behind `StoopFlag.designSystemV2Enabled` (reached in app code as `AppConstants.designSystemV2Enabled`). With the flag off, every legacy path stays byte-identical. Every new pure helper is `nonisolated` (the project defaults to MainActor isolation). New tunables live in their own `nonisolated enum` next to the helper (house style, e.g. `ForDaysUntilConstants`). No new feature flags, no `Constants.swift` edits.

Out of bounds for this spec: the park flow (`Views/WPParkFlowV2.swift`, `Views/WPParkSideCardV2.swift`, `Views/CurbPlacement*.swift`, and the park functions in `ContentView.swift`). DT35 PR2 (free drag of the parked car) is being built there right now.

## Open decisions (all have a recommended default; Kevin only needs to act if he disagrees)

1. **Green-only when zoomed out (PR2).** Recommend yes: between about 1.3 km and 2.2 km of visible height the map shows green curbs only, with a plain line saying so. This is honest (see PR2 reasoning). Alternative: no green-only band, just a hard cutoff earlier. Cheaper but loses the "where is anything free" view Kevin likes.
2. **Overlay cutoff goes from 0.04 deg (about 4.4 km tall) to 0.02 deg (about 2.2 km tall)** in Stoop. Kevin's neighborhood screenshot is about 0.021 deg, so it would already be off. Tunable constant.
3. **Window refresh granularity is 5 minutes** (PR1). The countdown still ticks every minute. "A few hours" would read "until 1:05 AM", "until 1:10 AM", on a 5 minute grid instead of the exact minute. If Kevin wants the exact minute back, the cost is a full recolor every minute (not recommended).
4. **Locate span becomes 0.008 deg (about 890 m tall, about 410 m wide)** (PR3). Needs Kevin's eyes on a device; one constant to retune.
5. **Plan a Trip destination is optional but pre-filled** (PR5): the map centre when the planner opens (which is the searched place right after a search, or the user right after Locate). "Remove destination" keeps the old whole-map trip.

## Read first

- **The Stoop map has two clocks and they disagree.** `lastEvaluatedAt` (`ContentView.swift:473`) drives the labels and countdown. Overlay rebuilds are called with either `lastEvaluatedAt` (region settle, tiles, selection: `ContentView.swift:4058`, `8398-8409`) or a fresh `.nowET` (goal tap, lever, picker, more than a dozen sites). So the green can be computed for one instant while the headline shows another.
- **The classification cache is keyed on `now`** (`Services/OverlayClassificationCache.swift:23-34`). Any new `now` invalidates every segment, so a "tick every minute" design pays a full re-evaluation of every loaded curb every minute, and a full overlay remove/add (`MapViewRepresentable.swift:2065-2095`).
- **The 0.04 deg cutoff sits above the tile cache.** `TileLoader` keeps 200 tiles (`Services/TileLoader.swift:133`), loads a 2 tile buffer (`TileLoader.swift:335`), tiles are about 0.002275 deg x 0.00226 deg (80 x 50 grid). A portrait phone at 0.04 deg wants about (17.6+4) x (10.8+4) = 320 tiles, which is more than the cap, so the LRU thrashes. The break-even is about 0.029 deg. At 0.02 deg it is about (8.8+4) x (5.4+4) = 120 tiles, at 0.012 deg about 70.

---

## PR1: R35-1 the goal window goes stale (highest priority, bug)

### Current behaviour and cause

Symptom: at 10:05 PM "A few hours until 1:04 AM, 3 h from now"; 20 minutes later still 1:04 AM and "3 h from now" (screenshot 3).

How the numbers are made:
- A few hours end = `min(from + 3h, overnightEnd(from))` (`Services/ParkingGoals.swift:160-175`, interval at `:116`). Overnight end = next 7 AM (or the lever hour 6 to 10) anchored on `from` (`ParkingGoals.swift:134-158`). For days Auto = start of day N from `from` via the ladder; manual = the Free until pick (`ContentView.swift:5070-5135`, `resolveForDaysManual`).
- The dock reads them in `v2GoalInput` (`ContentView.swift:4483-4515`) using `let now = lastEvaluatedAt`. The headline and countdown are `WPGoalCopy.headlineEnd/countdown(... now:)` (`DesignSystem/WPMapLogic.swift:134, 158`) over `WPGoalSheetInput.now` (`Views/WPMapScreenV2.swift:20-60`). The map green uses `parkUntilTarget`, set inside `rebuildOverlays` from the `now` it was called with (`ContentView.swift:3010-3065`).
- `lastEvaluatedAt` is set in only four places: launch (`ContentView.swift:4056`), `handleOnAppear` (`:6954` area / `:8389`), and `handleTimerTick` (`:8396`). The tick is `Timer.publish(every: 60 ...).autoconnect()` created inline in `mapLayerStack` (`ContentView.swift:3972`).

Why it froze (two causes; fix both, confirm the first with a log line before relying on it):
1. **The timer is rebuilt on every body pass.** `mapLayerStack` is a computed property of `ContentView.body`. `ContentView` re-evaluates constantly (location updates, tile loads, sheet state), and an inline `Timer.publish(...).autoconnect()` is a new publisher each time. A 60 s timer that is replaced more often than every 60 s never fires. Leading hypothesis.
2. **Nothing refreshes on foreground.** `handleScenePhaseChange(.active)` (`ContentView.swift:7013-7060`) resets stale For-days and clears an expired Park Until, but never sets `lastEvaluatedAt` and never rebuilds the Stoop goal window. If the screen locked for a few minutes the 60 s timer is also suspended.
3. Related: the paths that call `rebuildOverlays(at: .nowET)` colour the map for a fresh instant while the labels keep the stale `lastEvaluatedAt`, so after a goal tap the green and the "until" text can already disagree.

### Design: one window clock

New file `ios/WePark/WePark/DesignSystem/WPWindowClock.swift`, pure, `nonisolated`, no SwiftUI.

```swift
nonisolated enum WPWindowClock {
    /// Recolor grid. The map is coloured for a window that starts on this grid.
    static let step: TimeInterval = 300            // 5 minutes
    /// Floor `now` to the grid (epoch based; ET offsets are whole hours so it is wall-clock aligned).
    static func instant(_ now: Date) -> Date
    /// True when a recolor is due: the grid cell changed, or `now` is at/after the displayed end.
    static func needsRecolor(applied: Date, now: Date, displayedEnd: Date?) -> Bool
}
```

Rules:
- **Window start = `instant(now)`**, never later than `now` and less than 5 minutes before it. Every goal end (`ParkingGoals.target`, For days ladder, `ForDaysUntil.grid`, `resolveForDaysManual`) is computed `from: instant`, not from `now`.
- **Honesty (never green for a window that has partly passed).** The green is computed for `[instant, end]`, which contains `[now, end]`, so green means free for the whole remaining window and a little more. It can only be stricter than the exact window, never looser. The displayed end is the end the green was computed for (so "A few hours" can show 2 h 56 min left just before the next grid step, never more than 3 h). Test this as an invariant (below).
- **Countdown uses the live clock**, the end uses the grid. "until 1:05 AM" with "2 h 58 min from now", then "2 h 57 min from now" a minute later, then at 10:10 the end becomes 1:10 AM and the green recolors.
- **When the ticker or foreground finds `now >= displayedEnd`** (Overnight at 7:00, For days at midnight), recolor immediately, not at the next grid step.

Wiring in `ContentView.swift` (keep every hunk small and separate; this file is shared):
1. New `@State private var windowInstant: Date`, initialised from `WPWindowClock.instant(.nowET)`.
2. At the top of `rebuildOverlays(at:)` (`ContentView.swift:2970`), Stoop only: `let now = AppConstants.designSystemV2Enabled ? WPWindowClock.instant(Date.nowET) : now` and set `windowInstant = now` if changed. This one line fixes every caller (`.nowET` or `lastEvaluatedAt`), so a pan, a tile load and a goal tap all colour for the same instant, and a dead ticker still heals on the next interaction. (The `now` parameter is ignored for Stoop on purpose; leave a comment.)
3. `v2GoalInput` (`ContentView.swift:4483`): ends computed from `windowInstant`; `WPGoalSheetInput.now` = `windowInstant` (it is also what the free-curb count in `Views/WPSearchV2.swift:545-550` and the picker use as `from`, so the search card count, the picker grid and the map all agree without editing `WPSearchV2.swift`); add `liveNow: Date` (= `lastEvaluatedAt`) used only by `countdown` and the For days countdown in `WPGoalSheetInput` (`Views/WPMapScreenV2.swift:50-60`).
4. **Replace the inline Timer for Stoop** with a `.task` on `mapLayerStack` that survives body re-evaluation:
   ```swift
   .task(id: AppConstants.designSystemV2Enabled) {
       guard AppConstants.designSystemV2Enabled else { return }
       while !Task.isCancelled {
           // Sleep to the next wall-clock minute boundary (+0.5 s), so the countdown flips on the minute.
           try? await Task.sleep(for: .seconds(60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60) + 0.5))
           handleMinuteTick()
       }
   }
   ```
   `handleMinuteTick()`: `lastEvaluatedAt = .now`; `if WPWindowClock.needsRecolor(applied: windowInstant, now: lastEvaluatedAt, displayedEnd: <selected goal end>) { rebuildOverlays(at: lastEvaluatedAt) }`. In `handleTimerTick` (`:8396`) add an early `if AppConstants.designSystemV2Enabled { return }` so the legacy `Timer` is untouched and Stoop is not double-ticked.
5. `handleScenePhaseChange(.active)` (`:7013`): Stoop-only addition right after `resetStaleForDaysPick`: call `handleMinuteTick()` once. Also observe `UIApplication.significantTimeChangeNotification` and `.NSSystemClockDidChange` to call it (clock set, timezone, midnight).
6. **No flicker and no needless recolor.** In `rebuildOverlays`, after the classification loops and before `overlayGeneration += 1` (live-goal path `~:3200-3215`, trip path `~:3118`, current-state path `~:3280`): compute an order-independent signature (count per group plus a wrapping sum of `segment.id.hashValue`, plus selected coords/state, zoom band, detail mode, outside-coverage) and **skip publishing the payload when it equals the last one**. Within one 5 minute cell the classification cache hits (key `now` is now constant), so a pan re-evaluates nothing; at a cell change the evaluation runs once, and the overlay is only torn down and re-added if some curb actually changed colour. Expect that to be most cell changes.
7. Trip map: classification does not depend on `now` (`TripPlanning.isFree`, `Services/TripPlanning.swift:190-201`), so key the trip cache on `plan.arrival` instead of `now` (`ContentView.swift:3092`) so it survives ticks. The "trip is over" check (`:3083`) keeps comparing against the live clock, so it now fires within a minute. `WPTripMapCard`/`WPTripTopTag` already take `now: lastEvaluatedAt` (`:4311`, `:3327`) and tick with the countdown.
8. Free until picker (#220): `WPForDaysPickerV2` takes `now` (`Views/WPForDaysPickerV2.swift:87`) from `WPGoalSheetInput.now`, which is now `windowInstant`, so its grid minimum (Overnight end) is exactly what the map is coloured for. `resolveForDaysManual` already receives `now` from `rebuildOverlays`, so it gets the instant too. The picker's displayed grid only moves when the Overnight end moves (7 AM rollover); do not re-snap a pick on every cell, only when `snapped.date != pick` as today.

Edge cases:
- Cell change during a pan or pinch: the rebuild is cheap with the cache and the signature guard; no deferral logic needed.
- Backgrounded past the end: on `.active`, `needsRecolor` is true (`now >= displayedEnd`), so the first rebuild runs before the user can act. One stale frame is possible; the end label is recomputed in the same pass.
- Clock jumps backward (manual change): `instant` differs from `windowInstant`, so it recolors (compare with `!=`, not `>`).
- 6:55 to 7:00 AM Overnight: end 7:00 today until the grid cell flips to 7:00, then tomorrow 7:00 (`overnightEnd` treats 7:00 sharp as past, `ParkingGoals.swift:134-158`). At 7:00:30 the tick sees `now >= displayedEnd` and recolors immediately.
- Midnight: For days Auto's ladder end (`startOfDay(+N)`) changes at 00:00 ET; the cell flip recolors it. DST: grid is epoch-based, ends use `Calendar.easternTime` as today.
- Zoomed out (overlay off): `parkUntilTarget` and `windowInstant` still update (cheap); the payload is the empty one. Do not rebuild polylines.
- Trip active: live goal state is untouched (as today); only the trip card/tag clock ticks.

Acceptance criteria:
- [ ] Leave the app open on A few hours for 20 minutes: the end label moves in 5 minute steps (for example 1:00 AM, 1:05 AM ...) and the countdown changes every minute, without any pan or tap.
- [ ] Lock the phone 10 minutes, unlock: headline, countdown and green are current within one second of the app becoming active.
- [ ] The headline end, the tile sub-line, the countdown, the search card's "from now until ..." and the Free until picker's earliest time all use the same end for the same goal.
- [ ] At any moment the displayed A few hours window is between 2 h 55 min and 3 h long (except where capped by Overnight's end).
- [ ] A curb that turns green because a restriction ended appears at most 5 minutes after (cell change) and a curb whose restriction is about to start is never green for a window that includes it.
- [ ] A tick inside one 5 minute cell causes zero overlay removes/adds (verify with an `os_signpost` or a debug counter on `applyOverlayPayload`).
- [ ] A cell change in which no curb changed colour causes no overlay remove/add (signature guard).
- [ ] Trip map: the trip colour does not change as time passes; "Trip plan ended." appears within a minute after departure; `WPTripTopTag` dates stay correct.
- [ ] Overnight at 6:59 AM flips to tomorrow's 7 AM within one minute of 7:00.
- [ ] Flag off: no change (legacy `Timer` path still used).

Tests (new `WeParkTests/WPWindowClockTests.swift`, XCTest, no `Category` bare name):
- `instant` floors to 5 minutes, idempotent, `instant(now) <= now < instant(now) + 300` across a DST day and across midnight.
- Invariant: for every minute of a day and every goal, window `[instant, end]` contains `[now, end]` and `end > now`.
- Invariant (existing `GoalsReworkInvariantTests`): green(A few hours) is a superset of green(Overnight) is a superset of green(For days) still holds when evaluated `from: instant`.
- `needsRecolor`: false inside a cell, true on cell change, true when `now >= displayedEnd`, true when `now < applied` (clock back).
- Signature guard: pure helper `WPOverlaySignature.make(...)` equal for same input in a different order, different when one curb flips.
- Trip cache key independent of `now`.
- Manual (QA, Mac): optional DEBUG-only launch arg `-wpClockSkewMinutes N` added to `Date.nowET` and the tick (`Services/Date+ET.swift:54`) so QA can fast-forward instead of waiting 20 minutes. Compile it out of Release.

First step for the engineer: add a temporary `os_log` in `handleTimerTick` and run 5 minutes on the sim. If ticks fire normally the inline-timer hypothesis is wrong and cause 2 (foreground) plus cause 3 (clock mismatch) are the story; the fix above covers all three either way.

---

## PR2: R35-4 zoomed-out map (red blanket, thick curbs, lag)

### Current behaviour and cause

- Curb lines are 6 pt solid green or 6 pt dashed coral `[10, 8]` (`DesignSystem/WPCurbLines.swift:57-70`; width and dash come from `WP.CurbLine`).
- Width scaling only goes **down** when zoomed in: `CurbLineStyleV2.zoomScale` is 1 at or above 0.0035 deg and 0.5 at or below 0.0007 deg (`WPCurbLines.swift:123-134`). Above 0.0035 deg every zoom gets the full 6 pt. It is applied in the renderer (`Views/MapViewRepresentable.swift:3048-3054`) and on every settled region change (`rescaleCurbLines`, `:3300-3334`).
- Maths of the blanket: a portrait phone at 0.021 deg (screenshot 3) is about 2.3 km tall, so 1 pt is about 2.7 m and a 6 pt line paints about 16 m of an 18 m wide street. Two curbs per street and the dashes fill in. At 0.008 deg a 6 pt line is about 6 m. Screenshot 1's bars measure about 45 px (about 15 pt) which is more than the 6 pt maximum, so **step 0 for the engineer: measure on the sim at 0.003, 0.008, 0.021 deg what the rendered width actually is** (draw a 3 pt reference line next to a curb, or screenshot-measure) and report the multiplier before changing numbers. Suspects: overlay tiles rendered at one scale and re-scaled by MapKit between rebuilds, `region.span` mismatch right after an animated `setCamera` (`rescaleCurbLines` reads the span at settle), dash pattern scaled differently from width. Do not tune blind.
- Cutoff: `AppConstants.polylineHideSpanThreshold = 0.04` (`Services/Constants.swift:80`), checked in `rebuildOverlays` (`ContentView.swift:3074`) and in `v2Loading` (`:4457`). It is a rebuild-time check, so the overlay is only removed after the pan or zoom settles.
- Lag, estimated from the code (no profiler on this machine; confirm on device, see acceptance): (a) at 0.03 to 0.04 deg the tile working set (about 200 to 320 tiles) exceeds the 200 tile LRU, so tiles are decoded, evicted and decoded again while zooming (`TileLoader.swift:133, 335`); (b) at that span roughly 2,000 to 4,500 segments (about 2.3M segments per deg2 on average, denser in Midtown) are classified and then drawn as 5 `MKMultiPolyline` overlays, with a dashed stroke on the large "not green" majority; (c) every settle removes and re-adds every overlay (`MapViewRepresentable.swift:2065-2095`). A 0.02 deg cutoff cuts (a) to about 120 tiles, (b) to about 500 to 1,100 segments, and the green-only band cuts drawn lines by roughly 4 to 5x again (most curbs are not green).

### Change

New file `ios/WePark/WePark/DesignSystem/WPCurbZoomBand.swift`, pure, `nonisolated`:

```swift
nonisolated enum WPCurbZoomBand: Equatable { case full, greenOnly, off }
nonisolated enum WPCurbZoomConstants {
    static let fullMaxDelta: Double = 0.012      // up to ~1.3 km tall: red and green
    static let greenOnlyMaxDelta: Double = 0.020 // up to ~2.2 km tall: green only; above: off
    static let knots: [(delta: Double, width: CGFloat)] = [
        (0.0007, 3.0), (0.0035, 4.5), (0.008, 3.0), (0.012, 2.25), (0.016, 1.75), (0.020, 1.5)
    ]
    static let greenOnlyMinWidth: CGFloat = 2.0
}
static func band(latitudeDelta: Double) -> WPCurbZoomBand
static func width(latitudeDelta: Double, band: WPCurbZoomBand) -> CGFloat  // linear between knots, 0.25 pt steps
```

Rules:
1. **Widths.** Linear interpolation between the knots, quantized to 0.25 pt, clamped to 1.5 pt. The target is about 2 to 3.5 m of paint on the ground at every zoom (about one sixth of a street), instead of 6 to 16 m. Dash and dot patterns scale by `width / 6`, floored at 0.5. Green in the green-only band uses at least 2.0 pt so it never turns into a hairline. At 0.0035 deg (4.5 pt) the line is slightly thinner than today's 6 pt, which also answers "red reads like salmon blocks" up close. Replace `zoomScale` use in the renderer and `rescaleCurbLines` with this for Stoop **when not in Drive Mode**; drive keeps today's widths (Kevin prefers big, high-contrast curbs while driving; `parent.driveModeActive` is already available in the renderer, `MapViewRepresentable.swift:3073`). Selected-curb casing/line keep `WP.CurbLine.selected*` but scale with the same factor.
2. **Green-only band (0.012 to 0.020 deg).** In the Stoop branches of `rebuildOverlays` (live goal path, current-state path and trip path) drop every non-green group before building the payload: empty `restrictedNow`, `unknown`, `freeButRestrictionSoon`, `meteredActive`. Green stays exactly the same decision (`WPCurbVerdict.isParkable` / `TripPlanning.isFree`, same `now`, same end), so it still nests (green A few hours is a superset of Overnight is a superset of For days) and no curb that was not green at full zoom becomes green. Detail mode ("show all sign details") also draws green only in this band. Crossing a band boundary needs a rebuild: `handleRegionChanged` already calls `rebuildOverlays` on settle (`ContentView.swift:4052`); the signature guard from PR1 includes the band so the swap is skipped when nothing changed.
3. **Is green-only honest?** Yes, with a visible line. Omitting red cannot create a fake spot: every green line is still a strict-gate green, and a curb with no line is not claimed free. The risk is reading "no line" as "unknown or no data". So the band is always labelled (below), and the base-map rule "unknown, plate-only and commercial signs are red" is unchanged at full zoom. Do not draw a translucent "red wash" at this zoom; that is the blanket again.
4. **Earlier cutoff.** Stoop cutoff is `greenOnlyMaxDelta` (0.02 deg) instead of 0.04. Add `WPCurbZoomBand.band(...)` to `rebuildOverlays` (`ContentView.swift:3074`) and `v2Loading` (`:4457`) when Stoop; legacy keeps `polylineHideSpanThreshold`. `AppConstants.polylineHideSpanThreshold` itself is not edited. Existing tests that require the launch region to be inside it (`AmbientColorsAndChromeFixTests`, `AmbientDrivingLookTests:137-151`) still pass (launch is about 0.0036 deg); add the same check against the new constant.
5. **Plain hint.** `v2Pill` (`ContentView.swift:4464`) gets a new case ahead of the street-cleaning pill, only when `band != .full`, no trip-outside-coverage state, and not loading:
   - `.greenOnly`: "Green curbs only. Zoom in to see the rest."
   - `.off`: "Zoom in to see parking"
   Uses the existing `.info(String)` pill. It replaces the "Street cleaning in effect today" pill while zoomed out (that fact returns on zoom in). The hint must not show during Drive Mode or while the location-off or outside-coverage states own the pill.
6. **Rebuild cost.** Add `os_signpost` around the classification loop and `applyOverlayPayload`. Optional follow-up (not in this PR): skip `tileLoader.loadTiles` in Stoop when `latitudeDelta > 0.03` so zooming out does not decode tiles nobody can see; do this only if Instruments shows decode is hot after the cutoff change.

Edge cases:
- Pinch in progress: the old overlay stays until settle (as today). Acceptable; do not add per-frame work.
- Trip map and goal map use the same bands. A trip destination framed at 0.008 deg (PR5) is in the full band.
- At AX5 nothing changes in the map; the hint pill already wraps (`WPTopPill`); confirm it wraps to two lines and does not collide with the Locate/More buttons.
- Screens outside coverage (`v2OutsideCoverage`) keep the empty payload and their own card; no zoom hint there.
- Legend `showLegend` (`ContentView.swift:4486`) only applies in the full band.

Acceptance criteria:
- [ ] At 0.008 deg, curbs read as thin lines with clear gaps for the street between them; the red never merges into a mass (compare with screenshots 1 and 3).
- [ ] From 0.012 to 0.020 deg only green is drawn and the pill says "Green curbs only. Zoom in to see the rest."
- [ ] Above 0.020 deg no curbs are drawn and the pill says "Zoom in to see parking"; no "loading" pill.
- [ ] Green in the green-only band is exactly the set that is green when zoomed in (spot check 20 curbs across the three goals). Overnight green is contained in A few hours green; For days green is contained in Overnight green.
- [ ] Drive Mode curb widths are unchanged.
- [ ] Zooming from 0.003 to 0.03 and back on a device: no dropped-frame hitch longer than before the change (Instruments, Core Animation FPS) and no tile re-decode storm (loadTiles signposts). Record before and after numbers in the PR.
- [ ] The measured on-screen width at 0.003, 0.008 and 0.021 deg is recorded in the PR description next to the intended width.
- [ ] Flag off: no change.

Tests (new `WeParkTests/WPCurbZoomBandTests.swift`): band boundaries (0.012 is full, 0.0121 green-only, 0.020 green-only, 0.0201 off), width monotone non-increasing above 0.0035, width at the knots, quantization to 0.25, green floor 2.0, dash scale floor 0.5, `NaN`/0/negative input falls back to the full band and 4.5 pt (no crash; the loader already guards degenerate spans). Payload filter test: given a mixed set, green-only output equals the full output's green group (pure helper `WPCurbZoomBand.filter(payloadGroups:band:)`).

---

## PR3: R35-3 Locate zooms in too close

### Current behaviour and cause

"Locate" calls `recenterOnUser` (`ContentView.swift:6124`), which calls `recenterMap(on:usingUserFix: true)` (`:6216`). With the ambient look in effect (flag on, not driving) that does not use the 400 m region; it applies the **Cruise camera span**: `.tight` is `MapViewRepresentable.driveModeCameraSpan = 0.003 deg` (`Views/MapViewRepresentable.swift:550`) which is about 333 m tall and, on a portrait phone, only about 150 m wide, less than one avenue block (`Services/AmbientDrivingLook.swift:117-122`, applied at `ContentView.swift:6268-6292`; zoom step chosen by GPS accuracy, `:6228`). `.wide` (poor fix, cold launch) is 2x that (0.006 deg). Search results, the parked car and the Penn Station card all go through the same `recenterMap`, so they inherit the same building-level zoom.

### Change

- In `AmbientDrivingLook`, add Stoop spans that are independent of the Cruise span:
  ```swift
  nonisolated static let stoopTightSpan: CLLocationDegrees = 0.008   // about 890 m tall, 410 m wide: ~2-3 blocks around you, ~1.5 avenues
  nonisolated static let stoopWideSpan: CLLocationDegrees = 0.012    // poor GPS fix / cold launch (still the full red+green band)
  nonisolated static func span(for step: ZoomStep, cruiseSpan: CLLocationDegrees, stoop: Bool) -> CLLocationDegrees
  ```
  Stoop returns the Stoop spans; flag off returns today's `span(for:cruiseSpan:)` unchanged. Keep the accuracy guard (`maxTightHorizontalAccuracyMeters = 65`).
- `applyAmbientDrivingLook` (`ContentView.swift:6268`): pass `stoop: AppConstants.designSystemV2Enabled`. One small hunk in a shared file.
- **Consistency decision.** Locate, search results (`onDestinationResolved`, `ContentView.swift:4742`), the parked car recenter (`recenterOnCar`, `:6146`) and trip destination framing (PR5) all use the same Stoop span. **Drive Mode keeps 0.003 deg** (`driveModeCameraSpan`): a driver needs the next intersection large. The Stoop "End returns to this exact launch look" rule (A3.6.3) now returns to 0.008 deg because it restores the same `.tight` step; that is intended.
- The 400 m `streetLevelRecenterMeters` (`Constants.swift:461`) fallback used when the ambient look is not in effect is left alone.

Edge cases: the `.wide` to `.tight` tighten path (`shouldTighten`, `AmbientDrivingLook.swift:131-145`) still works because 0.008 < 0.012. User has pinched since the look was applied: unchanged (no fight with the user). The initial launch region (`initialLaunchRegion`, `ContentView.swift:6190-6210`) is not changed.

Land with or after PR2: at 0.008 deg the old 6 pt lines would look heavy; PR2's 3 pt there is what makes this zoom readable.

Acceptance criteria:
- [ ] Tap Locate in Midtown on a device: you see your block, the blocks on both sides and the next 2 to 3 streets with curbs (about 6 streets tall and about 1.5 avenues wide), not building footprints.
- [ ] Searching "Penn Station" and tapping a result frames the destination at the same zoom as Locate.
- [ ] Parked-car recenter uses the same zoom.
- [ ] Drive Mode camera distance is unchanged.
- [ ] A poor-GPS cold launch opens at 0.012 deg and tightens to 0.008 when a good fix arrives.
- [ ] Flag off: byte-identical spans.

Tests (extend `WeParkTests/AmbientDrivingLookTests.swift`): Stoop spans are 0.008 and 0.012, flag-off values unchanged, `stoopTightSpan < stoopWideSpan`, both are inside `WPCurbZoomConstants.fullMaxDelta` (so curbs show in both red and green), `altitudeForSpan(0.008)` is about 1,657 m.

---

## PR4: R35-2 sheets that are taller than their content

### Current behaviour and cause

The search card (destination card) is presented with `.presentationDetents([.medium, .large])` (`ContentView.swift:4757`), so it always opens at half screen. Inside, `destinationCard` is a `ScrollView` (greedy) above a pinned "Drive here" (`Views/WPSearchV2.swift:269-292`). When the content (header, count card, three goal chips) is shorter than half the screen, the ScrollView absorbs the leftover height and "Drive here" is pushed to the bottom: the empty gap in screenshot 1 (about 300 pt at 3x, roughly 100 pt of dead space).

### Change

- New helper `ios/WePark/WePark/DesignSystem/WPSheetSizing.swift`: a `ViewModifier` `.wpContentSizedSheet(height: Binding<CGFloat>, minimum:, extraDetents:)` that measures the content with `onGeometryChange(for: CGFloat.self ...)` (already used in `ContentView.swift:4331`) and exposes a `PresentationDetent.height(measured)` clamped to `[260, 0.85 x screen]`, plus `.large` for scrolling when the content is taller. `presentationBackgroundInteraction(.enabled(upThrough: <the content detent>))` so the map stays interactive beside the card (today it is `upThrough: .medium`, `ContentView.swift:4760`).
- Search destination card: measured detent plus `.large`. The search/typing state (suggestion list, keyboard) keeps `.medium` and `.large` as today; the detent set depends on `place == nil`. Content must be measured **excluding** the greedy ScrollView: replace the ScrollView with a `VStack` that falls back to a `ScrollView` only when `ViewThatFits` says the content does not fit the large detent (so it still scrolls at AX5).
- **AX5 layout stays as is.** Past accessibility sizes the card is `.large` only (same rule as the curb sheet, `v2UsesLargeSheetOnly`, `ContentView.swift:4703-4724`), chips stack vertically (already, `WPSearchV2.swift:~359`), the Close button keeps `WP.Target.minimum`.
- Apply the same helper to the other Stoop sheets only where it is measurably wasted. Audit list (measure on the sim at default size and AX5, change only if dead space is more than about 60 pt): curb sheet (`ContentView.swift:4703`, `Views/WPCurbSheetV2.swift:441`), My Car v2 sub-sheets `reminders`, `signs`, `leaving` (`Views/WPMyCarV2View.swift:294-304`), reminder priming (`ContentView.swift:5015`). **Excluded: `Views/WPParkSideCardV2.swift:85` and everything in the park flow** (DT35 PR2 owns them). Record the audit result (changed or "fits, left alone") per sheet in the PR description.
- Do not shrink touch targets to gain height. "Drive here" stays `.wpInkPill` full width, chips stay 56 pt high.

Edge cases: the count card appears after tiles load (`WPSearchCountKey` task), so the measured height changes once after open; animate the detent change with the default sheet animation and do not re-measure on every layout pass (round to 1 pt and ignore changes under 2 pt). Error text under the card adds a line; same mechanism. Landscape: clamp to the available height. Keyboard: not shown on the destination card (it unfocuses on select).

Acceptance criteria:
- [ ] The "Penn Station" card opens with no gap between the goal tiles and "Drive here" (spacing about 8 to 12 pt) and shows noticeably more map than build 35.
- [ ] Selecting a different goal chip or the count line changing from "No free curbs" to "12 free curbs" resizes the sheet smoothly without clipping.
- [ ] AX5: all content reachable (scroll if needed), no clipped text, Close and Drive here at least 44 pt.
- [ ] Dragging up still reaches `.large`; map interaction still works beside the card.
- [ ] Park flow files untouched in the diff.

Tests: pure sizing function `WPSheetSizing.clamp(measured:screenHeight:minimum:)` (min, max, rounding, NaN). A layout test in the style of `AXGoalDockTests`/`DriveAXLayoutTests` is welcome for the destination card at default and AX5 sizes if the harness supports it; otherwise a sim screenshot pair in the PR.

---

## PR5: F-1 Plan a Trip with a destination address

### Current behaviour

`Views/WPTripPlannerV2.swift` takes only arrival and departure. `TripPlan` is `{ arrival, departure }` (`Services/TripPlanning.swift:24-27`). The sheet is `.tripPlanner` (`ContentView.swift:2179-2191`); confirm sets `tripPlan` and rebuilds (`:2183-2187`). The trip map draws the same green gate over `[arrival, departure]` for every loaded segment (`ContentView.swift:3082-3137`), with `WPTripMapCard` at the bottom (`:4307-4316`), the "TRIP PLAN · NOT LIVE" tag (`WPTripTopTag`, `:3325`) and the dashed frame (`:3463`). The map stays wherever the user left it.

### Design

**Data.** `TripPlan` gets an optional destination so every existing `TripPlan(arrival:departure:)` call (tests, showcase `Phase6bShowcase`, `Phase2bShowcase`) still compiles:
```swift
nonisolated struct TripDestination: Equatable { let name: String; let address: String?; let latitude: Double; let longitude: Double }
nonisolated struct TripPlan: Equatable { let arrival: Date; let departure: Date; var destination: TripDestination? = nil }
```
Memberwise init must keep the two argument form working (give the new field a default and add an explicit init if the compiler does not synthesize it). `Equatable` includes the destination so changing it triggers the existing change paths. The plan is not persisted (it is `@State`, `ContentView.swift:627`), so no migration.

**Planner UI (`Views/WPTripPlannerV2.swift`, Stoop only).** A new first card "Where to?" above the quick picks:
- A full-width row, minimum 64 pt high like the date rows (`WPTripPlannerV2.swift:155-200`), label "Where to?", value = place name, second line = address or distance from the user. Tapping opens the destination picker. At AX sizes the label and value stack vertically (same `typeSize.isAccessibilitySize` pattern as `dateRow`).
- Default value when a fresh plan opens: **the map centre at that moment** (`region.center`, passed in from `ContentView`). Right after a search the map is centred on the searched place (`onDestinationResolved` recentres, `ContentView.swift:4742`), so this single rule covers "last search" and "map centre" and, right after Locate, "where I am". Name it by reverse geocoding the centre, best effort ("Near 350 5th Ave", falling back to "This part of the map" if the lookup fails or is offline; never block the sheet on it). Show up to three recents from `RecentDestinationsStore` as chips under the row for one tap changes (reuse the store, `Services/SearchCompleterDelegate.swift`).
- A "Clear" text button on the row (44 pt minimum) removes the destination (trip without a place = old behaviour, no framing).
- Editing an existing plan (`initialPlan != nil`, from "Change dates" or edit): preload `initialPlan.destination`; "Change dates" keeps the destination; the row says the saved place, not the map centre.
- If the chosen destination is outside Manhattan coverage (`AppConstants.isInManhattanCoverage`, `Constants.swift`): show the same fact card as search ("Not covered yet. WePark covers Manhattan today. Curbs here aren't mapped, so nothing is marked as free."; copy lives at `Views/WPSearchV2.swift:~316`, reuse the strings from a shared constant) and keep "Show map" enabled so the user can still look.

**Destination picker (new file `Views/WPTripDestinationPickerV2.swift`).** Swaps in place of the planner content inside the same `.large` sheet (no nested sheet): a search field, suggestion rows, recents.
- Reuse `SearchCompleterDelegate` (MKLocalSearchCompleter) and the same MKLocalSearch resolution with the 10 s timeout and the same two error strings that `WPSearchSheetV2.select` uses (`Views/WPSearchV2.swift:~470-505`: "Search timed out. Try again." and "Couldn't find that place. Check your connection and try again."). Do not refactor `WPSearchV2.swift` (PR4 edits it); extract the resolution into a new `Services/WPPlaceResolver.swift` and have only the new picker use it. A follow-up can point the search sheet at it.
- Rows outside coverage stay in the list, muted, with "not covered yet" (same as search).
- **No results**: empty state "No places found for '<query>'. Try a street address." (with a 44 pt "Clear" button); suggestions loading shows a spinner row.
- Tapping a row resolves to `WPResolvedPlace` (`WPSearchV2.swift:23-33`), maps to `TripDestination`, returns to the planner with the row filled. Add to `RecentDestinationsStore` on "Show map", not on mere selection.
- Big targets: rows `WP.Control.rowMinHeight`, field height 56, Back button 44 minimum. AX5: field above rows, no side by side.

**Trip map.**
- On confirm (`ContentView.swift:2183`): set `tripPlan`, then if it has a destination call `recenterMap(on: destination.coordinate)` (PR3 span, tiles load), which also frames the destination for a sheet that dismisses. If the plan has no destination the map stays put (old behaviour). On "Change dates" the map is not re-framed unless the destination changed.
- Green stays the single existing gate (`TripPlanning.isFree`, `ContentView.swift:3098`), over all loaded segments, so the user can pan to nearby areas; PR2's zoom bands apply (green-only and cutoff bands).
- `WPTripTopTag` "TRIP PLAN · NOT LIVE" is unchanged. The dashed violet frame is unchanged.
- **Summary line on `WPTripMapCard`** (`Views/WPTripPlannerV2.swift:228+`), one new optional `destinationSummary: String?` parameter under the headline. Computed in `ContentView` (not the view) by a new pure helper in `DesignSystem/WPTripDestinationSummary.swift`, which reuses `WPFreeCurbCounter.distance(from:to:)` (`DesignSystem/WPCurbSheetLogic.swift:709`), the 160 m "2 blocks" radius and `WPTileCoverage.covers` for honesty, but takes its green verdict from `TripPlanning.isFree(... strictSigns: AppConstants.designSystemV2Enabled)` over `[arrival, departure]` (the existing `WPFreeCurbCounter.count` only knows a goal window and only returns "nearest" when the count is zero, so a small trip variant is cleaner than editing that shared file).
  - Count above zero: "Near 350 5th Ave: 12 curbs free for your whole trip. The nearest is 400 ft away." (singular "1 curb is free"; reuse `WPFreeCurbCounter.nearestLine` wording style.)
  - Zero within 2 blocks, nearest known: "Near 350 5th Ave: no free curbs within 2 blocks for your whole trip. The nearest is 0.2 mi away."
  - Tiles for the area not loaded yet: "Checking curbs near 350 5th Ave." (never an estimate; if still unloaded after 10 s or offline: "Curb count isn't available right now.")
  - Outside coverage: "350 5th Ave is outside Manhattan. WePark can't show free curbs there yet." and no green is promised.
  - Recomputed when tiles load or the plan changes (key like `WPSearchCountKey`, `WPSearchV2.swift:35-41`, including loaded tile set and plan).
  - The card is capped at accessibility1 text (`WPTripPlannerV2.swift:~290`); the summary may wrap to 3 lines; it must not push the buttons off screen at AX5 (test), and the card must stay under about 45% of the screen height.

Edge cases:
- Destination is a place name, not an address (Penn Station): use the name as the headline, the address as the second line; the summary says "Near Penn Station".
- Destination changes while a trip is active (planner edit): replace `tripPlan`, re-frame, recompute summary; `exitTripPlan()` clears everything including the summary.
- Reverse geocode returns nothing: label "This part of the map".
- Dates change moves the plan to a weekend where the destination's curbs differ: the summary recomputes; no change to framing.
- Offline: MKLocalSearch fails, picker shows the timeout/connection string; planner still works with the default map-centre place.
- Trip over: "Trip plan ended." path unchanged.
- No loaded tiles at the destination because it is outside the 0.5 deg load span: not reachable in practice (framed at 0.008).

Acceptance criteria:
- [ ] Planner shows a "Where to?" row defaulting to the current map centre; after a search it shows that place; the row is at least 64 pt high.
- [ ] Typing an address shows suggestions; picking one fills the row; "No places found" appears for nonsense; a timeout shows the existing error string.
- [ ] "Show map" frames the destination at the PR3 zoom and draws green only for the trip window with the same gate as before; "TRIP PLAN · NOT LIVE" and the dashed frame are still shown.
- [ ] Card shows the summary in the formats above, with "free for your whole trip" wording; counts match what is visibly green around the destination within 2 blocks.
- [ ] Destination outside Manhattan: the planner row and the card say so and nothing is marked free.
- [ ] "Change dates" keeps the destination; clearing it gives the old whole-map trip.
- [ ] AX5: planner, picker and card readable, no clipped buttons.
- [ ] Flag off: legacy `TripPlannerSheet` unchanged.

Tests (new `WeParkTests/WPTripDestinationTests.swift`): `TripPlan` two-argument init still works; equality includes destination; summary helper cases (count, singular, zero with nearest, zero without nearest, tiles not loaded returns nil, outside coverage); summary agrees with `TripPlanning.isFree` on a fixture; default destination uses the map centre, falls back to "This part of the map"; picker filtering: empty query shows recents, no completions shows the empty state string. Extend `Phase6b` tests where `TripPlan` is built.

---

## Work streams and order

All streams are `@ios-engineer`. No `@backend-data`, `@pwa-maintainer`. Dispatch each PR in its own worktree (`isolation: "worktree"`). The dispatcher must paste the "Swift compile-failure classes (6)" list into every ios dispatch (including: bare `Category` is ambiguous in test targets, write `WePark.Category`). New test files must be added to the `WeParkTests` target. Builders share the Mac: one simulator per agent, check `df` and load average first (see memory notes).

| PR | Item | Priority | Main files | Notes |
|----|------|----------|------------|-------|
| PR1 | R35-1 window clock | 1 (bug) | new `DesignSystem/WPWindowClock.swift`; `ContentView.swift` (rebuild head, `v2GoalInput`, tick, scene, trip cache key); `Views/WPMapScreenV2.swift` (`WPGoalSheetInput.liveNow`) | Do first. |
| PR2 | R35-4 zoom bands, widths, hint | 2 | new `DesignSystem/WPCurbZoomBand.swift`; `DesignSystem/WPCurbLines.swift`; `Views/MapViewRepresentable.swift` (renderer + `rescaleCurbLines`); `ContentView.swift` (`rebuildOverlays` zoom guard, `v2Loading`, `v2Pill`) | Step 0 measurement first. |
| PR3 | R35-3 Locate span | 3 | `Services/AmbientDrivingLook.swift`; `ContentView.swift` (`applyAmbientDrivingLook`, one hunk) | Visually needs PR2 widths; code is independent. |
| PR4 | R35-2 sheet sizing | 4 | new `DesignSystem/WPSheetSizing.swift`; `Views/WPSearchV2.swift` (destination card only); `ContentView.swift` (two presentation modifiers); optionally `WPCurbSheetV2.swift`, `WPMyCarV2View.swift` | Not the park flow. |
| PR5 | F-1 trip destination | 5 | `Services/TripPlanning.swift`; `Views/WPTripPlannerV2.swift`; new `Views/WPTripDestinationPickerV2.swift`, `Services/WPPlaceResolver.swift`, `DesignSystem/WPTripDestinationSummary.swift`; `ContentView.swift` (`.tripPlanner` case, trip card call) | Frames the map with PR3's span; works with the old span if PR3 is not in yet. |

### Parallelism

- **Different files, run in parallel from day one:** PR1, PR3, PR4 and PR5 touch disjoint feature files. PR2 can also run in parallel but shares `ContentView.swift` hunks with PR1 (`rebuildOverlays` head vs the zoom guard further down, and `v2Pill`/`v2GoalInput` in the same neighborhood).
- **Shared file: `ContentView.swift` only.** Every PR adds small separated hunks there; whoever merges second rebases, never reformats. No two PRs edit the same function except PR1 and PR2 inside `rebuildOverlays` (head versus zoom guard and payload build): merge PR1 first, then rebase PR2.
- **`Views/WPSearchV2.swift`:** only PR4 edits it (PR1 deliberately does not; PR5 uses a new resolver file instead of refactoring it).
- **Serialize:** PR2 then PR3 for the visual result (land in the same build); PR5's framing looks right only with PR3.
- **Lanes for two agents:** Agent A: PR1 then PR2 (both touch the rebuild loop). Agent B: PR4 then PR5 then PR3. PR2 and PR3 should be in the same TestFlight build.
- DT35 PR2 (park flow) is untouched by all five PRs. The only overlap is the shared `ContentView.swift` file; keep hunks away from the park functions (`~:5277-5296` and the park card wiring).

## Out of scope follow-ups

- **F-2 Parking Hunt (optimal route to free parking near a destination).** Needs product workshopping; PR5's `TripDestination` and the destination picker are the building blocks.
- **R35-5 test reminder / short-window spot.** Not covered; separate small item.
- **Skip tile loading above about 0.03 deg in Stoop** (saves decode while zooming out). Only if Instruments shows it after PR2; listed in PR2 rule 6.
- **Point `WPSearchSheetV2` at the new `WPPlaceResolver`** to remove the duplicated MKLocalSearch resolution code; do after PR4 lands to avoid conflicts.
- **Legacy (flag off) timer bug.** The inline `Timer.publish` in `mapLayerStack` probably has the same freeze for the legacy UI; not fixed because legacy is frozen.
- **Exact boundary wake-ups** (a precise timer at the moment a restriction starts or ends, so green appears at the exact minute). The 5 minute grid is enough for now; revisit if Kevin notices the delay.
