# FT-6 — Customizable ASP Reminder Timing (Multi-Select Presets)

**Status:** Spec locked. Ready for `@ios-engineer` dispatch.
**Owner:** @ios-engineer (build), Tech Lead (spec).
**Depends on:** W7 merged (`SettingsView`, `notifyOnRestriction`, `notificationsMutedKey`); W7.5 merged (`parkUntil` parameter on `schedule(...)`); W6 merged (`NotificationScheduler`, `scheduleForTest`, `UNUserNotificationCenterProtocol`, `MockNotificationCenter`).
**Touches:** `Services/NotificationScheduler.swift`, `Services/Constants.swift`, `Views/SettingsView.swift`, `ContentView.swift` (settings hook only), `WeParkTests/NotificationSchedulerTests.swift` (new FT-6 test class).
**Does NOT touch:** PWA, Supabase, `project.pbxproj`, `Info.plist`, `Config.xcconfig*`.

---

## §0 — Open Decisions (Kevin's input required before code starts)

None. All product decisions for this feature are locked per the brief. The sub-decisions the spec author made unilaterally are listed at the end of this document (§9).

---

## §1 — Problem and User Story

**Problem.** Today WePark schedules exactly one notification per parked-car pin: 1 hour before ASP starts. A user who parks late at night and sleeps through a 6:00 AM fire has no backup. A user who parks early in the week wants an "is today the day?" heads-up the evening before. The 1-hour lead time is appropriate for many users but wrong for many others. There is no way to change it.

**User story.**

> Maria parks on Mott St (N side) Tuesday evening. She opens Settings and has three presets toggled on: "Night before," "1 hour before," and "15 minutes before." Wednesday night at 8:00 PM she gets a notification: "Move your car tomorrow — ASP starts Thu 7:00 AM." Thursday morning at 6:00 AM: "Move your car in 1 hour — ASP starts 7:00 AM." At 6:45 AM, still in her apartment: "Move your car in 15 minutes — ASP starts 7:00 AM." She makes it out in time.

**Why now.** TestFlight is live. The W6 notification infrastructure already uses a stable multi-slot identifier scheme (`r0`, `r1`, …) and prefix-based cancellation — the groundwork was laid specifically so this feature would be a clean extension, not a rewrite.

---

## §2 — Scope

### 2.1 In scope

- `ReminderOffsets` model: a `Codable` struct of five `Bool` fields persisted in `UserDefaults` under key `wepark_reminder_offsets`. Serialized as JSON.
- A new "Move-Your-Car Reminders" section in `SettingsView` with five toggles, one per preset.
- `AppConstants` additions: `reminderOffsetsKey`, `nightBeforeHourET` (value: 20), and the retirement of `notificationLeadTimeSeconds` as the scheduling driver (it stays in the file as a reference constant but is superseded by `ReminderOffsets`).
- Changes to `NotificationScheduler.scheduleRequest(...)` to compute a list of fire dates and enqueue one `UNNotificationRequest` per active preset.
- `scheduleForTest(for:loadedSegments:engine:now:)` extended to accept an optional `ReminderOffsets` parameter (defaults to reading `UserDefaults`), so tests can inject a specific reminder set without touching global state.
- Night-before computation using `Calendar.easternTime` with explicit DST-safe construction.
- Reschedule-on-settings-change hook in `ContentView` (mirrors the existing unmute reschedule path).
- 15 new unit tests in a `FT6ReminderTests` class using the existing `MockNotificationCenter` pattern.

### 2.2 Out of scope — do NOT build

- **Per-pin reminder set override.** One global setting only. Each `ParkedCar` continues to carry `notifyOnRestriction: Bool` as the master on/off; the global `ReminderOffsets` is the timing configuration. Per-pin override is deferred — see §8.
- **User-configurable "Night before" hour.** The 8:00 PM constant is `AppConstants.nightBeforeHourET`. Making this user-configurable is deferred — see §8.
- **Additional presets** beyond the five locked ones (e.g. 3h, 4h, 24h).
- **Notification actions** (snooze). Out of scope per W6 spec; still deferred.
- **PWA, Supabase, or backend changes.** iOS only.

---

## §3 — Architecture

### 3.1 Codebases touched

| Codebase | Files | Nature of change |
|---|---|---|
| iOS | `Services/Constants.swift` | Add `reminderOffsetsKey`, `nightBeforeHourET`; keep `notificationLeadTimeSeconds` as named constant only |
| iOS | `Services/NotificationScheduler.swift` | Replace single-request logic with multi-request loop |
| iOS | `Views/SettingsView.swift` | Add "Move-Your-Car Reminders" section with 5 toggles |
| iOS | `ContentView.swift` | Add reschedule-on-settings-change hook (one `.onChange` call) |
| iOS | `WeParkTests/NotificationSchedulerTests.swift` | New `FT6ReminderTests` class at end of file |

No backend, no PWA, no tile data.

### 3.2 Data flow

```
UserDefaults["wepark_reminder_offsets"]
        |
        v
ReminderOffsets (Codable struct)      <── SettingsView toggles write here
        |
        v
NotificationScheduler.schedule(for:...) reads ReminderOffsets from UserDefaults
   for each active preset:
       compute fireDate
       guard fireDate > now
       guard fireDate <= parkUntil (if set)
       enqueue UNNotificationRequest(id: "wepark.pin.<carID>.r<N>")
```

Cancellation is unchanged: `cancelAll(for:)` removes all requests matching the prefix `"wepark.pin.<car.id.uuidString>"` — which removes `r0` through `r4` (all five slots) without needing to know which presets were active at scheduling time.

---

## §4 — Data Model: `ReminderOffsets`

### 4.1 Struct definition (pseudocode interface — not Swift code)

```
struct ReminderOffsets: Codable, Equatable {
    var remind15Min:    Bool   // fires restrictionStart - 15 * 60
    var remind30Min:    Bool   // fires restrictionStart - 30 * 60
    var remind1Hour:    Bool   // fires restrictionStart - 3600       (the current default)
    var remind2Hours:   Bool   // fires restrictionStart - 7200
    var remindNightBefore: Bool  // fires 20:00 ET the prior calendar evening
}
```

Default value (first run, or missing key): `ReminderOffsets(remind15Min: false, remind30Min: false, remind1Hour: true, remind2Hours: false, remindNightBefore: false)`.

This default reproduces today's single-1h-notification behavior exactly. Existing users see no change on upgrade.

### 4.2 Preset-to-ruleIndex mapping (stable — never reorder)

| ruleIndex | Preset | Lead seconds |
|---|---|---|
| 0 | 15 minutes before | 900 |
| 1 | 30 minutes before | 1800 |
| 2 | 1 hour before | 3600 |
| 3 | 2 hours before | 7200 |
| 4 | Night before | special (§5.2) |

Stability guarantee: the mapping from ruleIndex to preset is permanent. Adding presets in a future version must use indices 5+. This ensures that a request scheduled with `r2` (1h) is always cancelled and re-created under `r2`, not accidentally left as an orphan.

### 4.3 Persistence

`UserDefaults` key: `AppConstants.reminderOffsetsKey` = `"wepark_reminder_offsets"`.

Serialization: `JSONEncoder().encode(offsets)` → `Data` → write with `UserDefaults.set(_:forKey:)`. Read with `UserDefaults.data(forKey:)` → `JSONDecoder().decode(ReminderOffsets.self, from:)`. Both operations are synchronous on the calling thread (same pattern as existing `UserDefaults`-backed state in the app).

Missing key decode path: if `UserDefaults.data(forKey: reminderOffsetsKey)` returns `nil`, return `ReminderOffsets.default` (the 1h-only value). Do not crash or throw. This is the first-run and the upgrade path for existing users.

Static helper on `ReminderOffsets`:
```
static func load(from defaults: UserDefaults = .standard) -> ReminderOffsets
static func save(_ offsets: ReminderOffsets, to defaults: UserDefaults = .standard)
```

Injecting a custom `UserDefaults` instance into these helpers is required for unit tests that must not pollute `UserDefaults.standard`. The pattern is identical to `BackgroundNoteGate` in `Constants.swift`.

### 4.4 Relation to `notificationLeadTimeSeconds`

`AppConstants.notificationLeadTimeSeconds` (`= 1 * 3600`) remains in `Constants.swift` as a named constant. The FT-6 scheduler reads lead times from the preset table (§4.2), not from this constant. Do not delete the constant — it is referenced in test comments and the W6 doc. Add a code comment: `// Superseded by ReminderOffsets.remind1Hour preset in FT-6. Retained for documentation.`

---

## §5 — Scheduler Changes

### 5.1 Top-level change to `schedule(for:...)`

The existing `schedule(for:...)` public method keeps its signature unchanged. Inside it, after all the existing guards (mute, notifyOnRestriction, segment resolution, isUnrestricted, isActiveNow), the logic changes from:

> compute one fireDate → one guard → one `scheduleRequest` call

To:

> load `ReminderOffsets` from `UserDefaults` → compute `restrictionStart = now + restriction.hours * 3600` → iterate active presets → compute one fireDate per preset → per-preset guards → one `scheduleRequest` call per preset that passes guards

The `getNotificationSettings` async callback wraps the entire iteration loop (same as today — the authorization check happens once, then all valid requests are enqueued inside the callback).

### 5.2 Restriction-start absolute date

```
let restrictionStart: Date = now.addingTimeInterval(restriction.hours * 3600)
```

This is the anchor for all relative presets. The existing code computes `fireDate = now + hours*3600 - leadTime`, which is equivalent to `restrictionStart - leadTime`. FT-6 makes the intermediate value explicit.

### 5.3 Per-preset fireDate computation

**Relative presets (15min, 30min, 1h, 2h):**
```
fireDate = restrictionStart - leadSeconds
```
where `leadSeconds` is the value from the preset table in §4.2.

**Night-before preset (ruleIndex 4):**

See §5.4 for the full algorithm. The result is a `Date` representing 20:00 ET on the calendar evening prior to the restriction day, or `nil` if that moment is already in the past.

### 5.4 Night-before computation (DST-safe)

The night-before fireDate is computed as follows. All steps use `Calendar.easternTime`.

1. Extract the ET calendar day of `restrictionStart`:
   ```
   let restrictionComponents = Calendar.easternTime.dateComponents([.year, .month, .day], from: restrictionStart)
   ```

2. Subtract 1 calendar day to get the prior evening's date:
   ```
   let priorDay = Calendar.easternTime.date(byAdding: .day, value: -1, to: restrictionStart)!
   let priorComponents = Calendar.easternTime.dateComponents([.year, .month, .day], from: priorDay)
   ```

3. Build 20:00 ET on that prior day using `date(from:)` — the DST-safe construction already used throughout the project for `UNCalendarNotificationTrigger`:
   ```
   var fireComponents = DateComponents()
   fireComponents.year   = priorComponents.year
   fireComponents.month  = priorComponents.month
   fireComponents.day    = priorComponents.day
   fireComponents.hour   = AppConstants.nightBeforeHourET   // 20
   fireComponents.minute = 0
   fireComponents.second = 0
   fireComponents.timeZone = .easternTime
   let nightBeforeDate = Calendar.easternTime.date(from: fireComponents)!
   ```

4. Apply the past-guard: `guard nightBeforeDate > now else { skip this preset }`.

**DST correctness:** Using `Calendar.easternTime.date(from: fireComponents)` with `fireComponents.timeZone = .easternTime` produces the correct absolute UTC instant for 20:00 ET regardless of whether the prior evening is in EST (UTC-5) or EDT (UTC-4). The `UNCalendarNotificationTrigger` built from the resulting date's components (extracted again via `Calendar.easternTime.dateComponents`) will fire at the right wall-clock moment. This is the same pattern used in `scheduleRequest` for all existing requests.

**Example (DST boundary — spec-required test case):**
- Restriction on Sunday 2026-03-08 at 07:00 ET (the morning DST springs forward, clocks jump 02:00→03:00).
- Night-before date: Saturday 2026-03-07 at 20:00 ET (= 20:00 EST = 01:00 UTC on 2026-03-08). The `date(from:)` call above produces the correct absolute UTC instant because it reads the ET components explicitly.
- The trigger fires Saturday evening at the correct local time. No floating-point arithmetic involved; no "hours subtracted from midnight" arithmetic that would break at the spring-forward boundary.

### 5.5 Per-preset guard sequence

For each active preset, in order:

1. `guard fireDate > now` — skip reminders already in the past (e.g. park at 6:50 AM for a 7:00 AM restriction: 15min reminder fires at 6:45 AM, which is in the past → skip; but the 1h and 2h reminders are also past → also skipped; the night-before was yesterday → also skipped. Result: zero notifications scheduled, which is correct).
2. `if let parkUntil = parkUntil, fireDate > parkUntil { skip }` — W7.5 guard, unchanged semantics. Applied per-reminder: a 2h reminder that fires after `parkUntil` is skipped, but a 15min reminder that fires before `parkUntil` still fires.

### 5.6 Per-request content

Each request uses the existing `buildContent(for:restriction:engine:segment:now:)` builder. The content is the same for all presets in this first iteration, with **one tailored field: the notification body**.

The body must indicate the lead time so the user understands the urgency without opening the app. Replace the generic body template with a per-preset lead phrase:

| Preset | Body prefix (replaces "starts `<timeLabel>`") |
|---|---|
| 15 min before | `"<label> starts in 15 minutes. Move by <time>."` |
| 30 min before | `"<label> starts in 30 minutes. Move by <time>."` |
| 1 hour before | `"<label> starts in 1 hour. Move by <time>."` |
| 2 hours before | `"<label> starts in 2 hours. Move by <time>."` |
| Night before | `"<label> starts tomorrow at <time>. Move your car by then."` |

The `<label>` and `<time>` values come from `restriction.label` and `engine.nextRestrictionTimeLabel(hours:now:)` as today. The "Night before" phrasing uses "tomorrow" unconditionally — this is always accurate because the night-before preset only fires the evening before the restriction day.

The title is unchanged: `"Move your car — <street> (<side>)"`.

The `userInfo` payload is unchanged: `wepark_car_id` and `wepark_action = show_car_detail`.

The request identifier is `NotificationScheduler.notificationID(for: car, ruleIndex: N)` where `N` is the ruleIndex from §4.2.

### 5.7 `scheduleForTest` changes

`scheduleForTest` needs the same multi-reminder logic. To avoid test state leaking through `UserDefaults.standard`, add an optional `offsets: ReminderOffsets?` parameter (default `nil`). When `nil`, read from `UserDefaults.standard` (production behavior). When non-nil, use the provided value directly.

New signature:
```
internal func scheduleForTest(
    for car: ParkedCar,
    loadedSegments: [Segment],
    engine: ParkingRulesEngine,
    now: Date,
    offsets: ReminderOffsets? = nil
)
```

Existing tests pass `nil` implicitly, which reads `UserDefaults.standard`. Since existing tests call `UserDefaults.standard.removeObject(forKey: AppConstants.reminderOffsetsKey)` in `setUp()` (new requirement — add this to the existing `setUp()`), missing key → `ReminderOffsets.default` → single 1h reminder → existing tests continue to pass with `addedRequests.count == 1`.

**Note for `@ios-engineer`:** Add `UserDefaults.standard.removeObject(forKey: AppConstants.reminderOffsetsKey)` to both `setUp()` and `tearDown()` of the existing `NotificationSchedulerTests` class and the existing `W7NotificationSchedulerTests` class. This is a one-line addition per class and ensures FT-6 tests don't bleed into pre-existing tests.

### 5.8 iOS pending-notification cap

iOS enforces a 64-pending-notification cap per app. With 5 presets and 1 active pin, FT-6 enqueues at most 5 requests. This is well within budget. No mitigation or pruning logic is needed. Document this in a code comment in the new scheduling loop.

---

## §6 — Settings UI

### 6.1 New section in `SettingsView`

Add a new `Section` between the existing "Notifications" section (global mute toggle) and the existing "About" section (version footer). Title: `"Move-Your-Car Reminders"`. Contains 5 `Toggle` rows:

```
Section("Move-Your-Car Reminders") {
    Toggle("15 minutes before", isOn: $offsets.remind15Min)
    Toggle("30 minutes before", isOn: $offsets.remind30Min)
    Toggle("1 hour before",     isOn: $offsets.remind1Hour)
    Toggle("2 hours before",    isOn: $offsets.remind2Hours)
    Toggle("Night before (8 PM)", isOn: $offsets.remindNightBefore)
}
```

The section header is sufficient context. No footer text is required in this iteration.

**Disabled state:** When the global notifications mute toggle is OFF (i.e. `notificationsMuted == true`), grey out the entire "Move-Your-Car Reminders" section by applying `.disabled(notificationsMuted)` to the section. The toggles are not interactive while global notifications are muted. This prevents a confusing state where the user configures reminder timing but global notifications are off.

**At-least-one guard:** Do not enforce "at least one preset must be active" in the UI. If the user turns off all five toggles, the result is zero notifications scheduled — which is equivalent to turning off `notifyOnRestriction` on the pin. This is a valid user choice. No warning is needed.

### 6.2 State ownership

`SettingsView` needs access to the `ReminderOffsets` value. The cleanest approach is a `@Binding var offsets: ReminderOffsets` parameter added to `SettingsView`, following the existing pattern of `@Binding var notificationsMuted: Bool`. `ContentView` owns a `@State private var reminderOffsets: ReminderOffsets` initialized from `UserDefaults` in `.task` (same initialization pattern as `notificationsMuted`).

`SettingsView` initializer:
```
// Updated initializer (new offsets parameter added):
init(
    notificationsMuted: Binding<Bool>,
    offsets: Binding<ReminderOffsets>,
    onUnmute: @escaping () -> Void,
    onOffsetsChange: @escaping () -> Void,
    appVersion: String,
    buildNumber: String
)
```

`onOffsetsChange` is called whenever any toggle changes. `ContentView` uses this closure to persist and reschedule.

### 6.3 Persistence on change

Inside the `Toggle` binding setter (or via `.onChange(of: offsets)` on the section), call `ReminderOffsets.save(offsets, to: .standard)` then call `onOffsetsChange()`.

The cleanest implementation: use a single `.onChange(of: offsets)` on the Form (since `ReminderOffsets` is `Equatable`) that calls `ReminderOffsets.save(newOffsets)` and then `onOffsetsChange()`. Do not write to `UserDefaults` inside individual toggle setters.

### 6.4 Reschedule-on-settings-change hook in `ContentView`

`ContentView` receives `onOffsetsChange`. The closure body:

```swift
// (pseudocode — not production code)
guard let car = parkPinService.parkedCar,
      car.notifyOnRestriction,
      !notificationsMuted else { return }

NotificationScheduler.shared.cancelAllThenSchedule(
    for: car,
    oldCarID: car.id,
    loadedSegments: tileLoader.segments,
    engine: engine
)
```

Note: `cancelAllThenSchedule` takes an `oldCarID` that matches `car.id` here because we want to cancel the CURRENT car's notifications (not a prior car's). This forces the prefix-cancel before re-scheduling with the new offsets. The net effect: old requests (`r0`–`r4` for the old preset combination) are removed and new requests (for the newly active preset combination) are enqueued.

This mirrors the existing unmute reschedule at `ContentView.swift:1964` (the `handleNotificationsMutedChange` path). The new `onOffsetsChange` closure is the sole new hook; no other `ContentView` method is touched.

`ContentView` also reads `reminderOffsets` in `.task` alongside the existing `notificationsMuted` initialization:
```
reminderOffsets = ReminderOffsets.load(from: .standard)
```
And in the `scenePhase == .active` path (line ~1795) where `notificationsMuted` is refreshed from `UserDefaults`, also refresh `reminderOffsets`:
```
reminderOffsets = ReminderOffsets.load(from: .standard)
```

---

## §7 — Backward Compatibility

### 7.1 Existing 1h notification behavior preserved

`ReminderOffsets.default` = `{remind1Hour: true, all others: false}`. An existing user upgrading from pre-FT-6 has no `wepark_reminder_offsets` key in `UserDefaults`. On first launch after upgrade, `ReminderOffsets.load()` returns the default value. The scheduler enqueues exactly one request at `r2` (1h before). The existing `r0` request (which was the old 1h slot) will be cancelled-and-replaced on the next pin-drop event or settings-change event. Until the user explicitly changes a setting or drops a new pin, the old `r0` notification continues to exist in the system — it fires correctly because the fire time was computed correctly when it was scheduled. There is no stale-notification risk: the body copy and fire time are unchanged.

### 7.2 Existing r0 notifications replaced by prefix cancellation

When `cancelAllThenSchedule` is called after FT-6 ships, it cancels all requests matching `"wepark.pin.<carID>"` — which includes any `r0` request scheduled by pre-FT-6 code. It then enqueues new requests using the FT-6 preset ruleIndexes. The old `r0` slot will be reused if the 15min preset is active (`r0` now maps to 15min). If the 15min preset is off, `r0` is simply not re-scheduled. There are no orphaned requests. No migration script needed.

### 7.3 `notificationLeadTimeSeconds` fate

The constant stays in `Constants.swift` with an updated doc comment. It is no longer read by `NotificationScheduler` in the scheduling path. Existing tests that assert `addedRequests.count == 1` remain passing because `ReminderOffsets.default` yields exactly one active preset.

---

## §8 — Work Streams

Single stream — this feature is iOS-only with no backend or PWA dependency.

| Stream | Agent | Parallel with | Serializes after |
|---|---|---|---|
| FT-6 iOS implementation | @ios-engineer | Nothing (sole stream) | Main branch at current HEAD |

The work can be broken into two sub-tasks if the engineer prefers, but they are in the same file set and do not parallelize:

1. Data model + scheduler changes (`Constants.swift`, `NotificationScheduler.swift`, `NotificationSchedulerTests.swift`).
2. Settings UI (`SettingsView.swift`, `ContentView.swift`).

---

## §9 — Acceptance Criteria

Tests are in a new `final class FT6ReminderTests: XCTestCase` appended to `NotificationSchedulerTests.swift`. All use `MockNotificationCenter`, `scheduleForTest(for:...offsets:)`, and `nsDate`/`nsCar`/`nsSegment` helpers defined in the existing `XCTestCase` extension.

---

**AC-FT6.1 — Default serialization and round-trip**

Given `ReminderOffsets.default`, encode to `Data` via `JSONEncoder`, decode via `JSONDecoder`. The decoded value must equal `ReminderOffsets(remind15Min: false, remind30Min: false, remind1Hour: true, remind2Hours: false, remindNightBefore: false)`. Assert `decoded == ReminderOffsets.default`. Assert `decoded.remind1Hour == true`. Assert all others `== false`.

**AC-FT6.2 — Missing UserDefaults key returns default**

Call `ReminderOffsets.load(from: ephemeralDefaults)` where `ephemeralDefaults` is a fresh `UserDefaults(suiteName: "ft6-test-suite")` with no key set. Assert result equals `ReminderOffsets.default`.

**AC-FT6.3 — Multi-preset scheduling: N requests for N active presets**

Given a segment with a restriction 3h away (Thu 2026-05-07 04:00 ET, ASP Mon/Thu 7:00am), a car with `notifyOnRestriction: true`, and `offsets = ReminderOffsets(remind15Min: true, remind30Min: false, remind1Hour: true, remind2Hours: true, remindNightBefore: false)`:

Call `scheduleForTest(for: car, ..., offsets: offsets)`. Assert `mockCenter.addedRequests.count == 3`. Assert the request identifiers are exactly `["wepark.pin.<carID>.r0", "wepark.pin.<carID>.r2", "wepark.pin.<carID>.r3"]` (set-equal, any order). This confirms the ruleIndex-to-preset mapping from §4.2.

**AC-FT6.4 — Correct fire times for relative presets**

Using the same setup as AC-FT6.3, extract the `UNCalendarNotificationTrigger.dateComponents` for each of the three requests.

- r0 (15min): fire hour = 6, fire minute = 45 (7:00 AM − 15min).
- r2 (1h): fire hour = 6, fire minute = 0 (7:00 AM − 1h).
- r3 (2h): fire hour = 5, fire minute = 0 (7:00 AM − 2h).

All `dateComponents.day == 7`, `month == 5`. All triggers use `Calendar.easternTime` (consistent with `testTriggerUsesEasternTime` in the existing suite).

**AC-FT6.5 — Per-reminder past-guard skipping**

Given now = Thu 2026-05-07 06:50 ET (10 minutes before 7:00 AM ASP), restriction ~10min away.

Active presets: all five. Call `scheduleForTest(...)`. Assert `mockCenter.addedRequests.count == 1`. The one request has identifier `r0` (15min before fires at 06:45 — which is PAST — so it is skipped; 30min fires at 06:30 — past; 1h at 06:00 — past; 2h at 05:00 — past; night-before was 8pm yesterday — past). All five are in the past → zero. **Correction: check this math.** 10 minutes until 7:00 AM → restrictionStart = 07:00. Firings: 15min = 06:45 (past at 06:50), 30min = 06:30 (past), 1h = 06:00 (past), 2h = 05:00 (past), night-before = yesterday 20:00 (past). Assert `count == 0`.

Separately: given now = Thu 2026-05-07 06:50 ET with a restriction at 7:30 AM (40min away): 15min fires 07:15 (future), 30min fires 07:00 (future), 1h fires 06:30 (past), 2h fires 05:30 (past), night-before past. Assert `count == 2`. Assert identifiers include `r0` and `r1`.

**AC-FT6.6 — Night-before fires at 20:00 ET the prior evening**

Given a restriction on Monday 2026-05-11 at 07:00 ET (ASP Mon/Thu). Now = Friday 2026-05-08 12:00 ET (restriction is ~67h away).

Active preset: `remindNightBefore = true` only. Call `scheduleForTest(...)`. Assert `addedRequests.count == 1`. The trigger for request `r4` must have `dateComponents.day == 10` (Sunday May 10), `month == 5`, `hour == 20`, `minute == 0`. This is 8:00 PM ET on Sunday, the evening before Monday ASP.

**AC-FT6.7 — Night-before skip-if-past**

Given a restriction on Monday 2026-05-11 at 07:00 ET. Now = Sunday 2026-05-10 21:00 ET (9:00 PM — 1 hour AFTER the night-before fire time).

Active preset: `remindNightBefore = true` only. Assert `addedRequests.count == 0` (night-before fire time 20:00 is in the past at 21:00).

**AC-FT6.8 — Night-before same-day skip**

Given now = Monday 2026-05-11 06:00 ET, restriction at 07:00 ET (1h away, same day). Active preset: `remindNightBefore = true` only. The night-before fire time would be Sunday 2026-05-10 20:00 ET — which is in the past. Assert `addedRequests.count == 0`.

**AC-FT6.9 — Night-before DST boundary (spring forward)**

Given a restriction on Sunday 2026-03-08 at 07:00 ET (clocks spring forward 02:00→03:00 that morning). Now = Saturday 2026-03-07 10:00 ET. Active preset: `remindNightBefore = true` only.

Expected night-before fire: 2026-03-07 20:00 ET (= 20:00 EST = 01:00 UTC Sunday). Extract trigger components: `day == 7`, `month == 3`, `hour == 20`, `minute == 0`. Assert these values. Additionally assert `addedRequests.count == 1` (the fire time is in the future at 10:00 AM Saturday).

**AC-FT6.10 — Single-preset default matches prior behavior**

Given `offsets = ReminderOffsets.default` (i.e. `remind1Hour = true` only), restriction 3h away. Assert `addedRequests.count == 1`. Assert identifier = `"wepark.pin.<carID>.r2"`. Assert trigger `dateComponents.hour == 6` (fire at 6:00 AM for a 7:00 AM restriction). This is the literal prior-behavior parity test.

**AC-FT6.11 — notifyOnRestriction = false blocks all presets**

Given `offsets` with all five presets active. Car has `notifyOnRestriction = false`. Assert `addedRequests.count == 0`.

**AC-FT6.12 — Global mute blocks all presets**

Set `UserDefaults.standard.set(true, forKey: AppConstants.notificationsMutedKey)`. Given `offsets` with all five presets active, `notifyOnRestriction = true`. Call `scheduleForTest(...)`. Assert `addedRequests.count == 0`. Clean up mute key in `tearDown()`.

**AC-FT6.13 — Cancellation removes all ruleIndexes by prefix**

Schedule with all five presets active (`addedRequests.count == 5`). Populate `mockCenter.pendingRequests` from those added requests. Call `cancelAll(for: car)` (using an `expectation` for the async callback as in T-W6.7). Assert `mockCenter.pendingRequests.count == 0`. Assert `mockCenter.removedPendingIdentifiers` contains identifiers for all five ruleIndexes (`r0`–`r4`).

**AC-FT6.14 — parkUntil guard is per-reminder**

Given now = Thu 2026-05-07 04:00 ET, restriction at 07:00 AM. parkUntil = 06:30 AM ET (90 minutes from now).

Active presets: 1h before and 15min before.
- 1h fires at 06:00 AM — before `parkUntil` (06:30 AM) → schedules.
- 15min fires at 06:45 AM — after `parkUntil` (06:30 AM) → skipped.

Assert `addedRequests.count == 1`. Assert identifier = `r2` (1h).

**AC-FT6.15 — `ReminderOffsets.load` + `save` round-trip via injected defaults**

Use `UserDefaults(suiteName: "ft6-roundtrip-suite")`. Save `ReminderOffsets(remind15Min: true, remind30Min: false, remind1Hour: false, remind2Hours: true, remindNightBefore: true)`. Load from same suite. Assert loaded value equals the saved value field by field.

---

### Live-UI smoke gate (non-automated — Kevin executes before merge)

The following two smoke checks must pass and be documented in the QA report before merge:

**Smoke A — Settings section renders and persists.** Open Settings sheet. Confirm the "Move-Your-Car Reminders" section appears below the global notifications toggle and above the version footer. Toggle "Night before" ON. Background and re-launch the app. Reopen Settings. Confirm "Night before" is still ON. Toggle it OFF. Close settings. Confirm no crash.

**Smoke B — Multiple notifications enqueue.** Drop a pin on a block with a restriction 2+ hours away. In Settings, activate "1 hour before" + "15 minutes before." Navigate to `Xcode → Debug → Simulate Notification` or use `UNUserNotificationCenter.getPendingNotificationRequests` via the Xcode memory graph / breakpoint to inspect the queue. Confirm exactly 2 pending requests with identifiers `r0` and `r2`. Alternatively, verify by waiting: in the sim, set the system clock forward past the 15-minute fire time but before the 1-hour fire time and confirm only the 15-min notification delivered. (The injection-dump approach is strongly preferred over waiting.)

---

## §10 — Out of Scope Follow-ups

| Item | Rationale for deferral |
|---|---|
| **Per-pin reminder set override.** Let the user configure a different reminder set per park session at pin-drop time. | Adds scope to `ParkConfirmView`, `ParkedCarDetailView`, `ParkedCar.swift` (new Codable field), and the scheduling path. No user demand yet — validate global setting first on TestFlight. |
| **User-configurable "Night before" hour.** Let the user pick 7 PM, 8 PM, 9 PM, etc. | Adds a picker to `SettingsView` and a new `UserDefaults` key. The 8 PM constant covers the majority use case. `AppConstants.nightBeforeHourET` is named for easy future extraction. |
| **"Last call" preset (5 minutes or 10 minutes before).** | Useful but adds another toggle. Validate 15min as the shortest useful lead time via TestFlight feedback first. |
| **Snooze action on notification banner.** | Requires `UNNotificationAction` + category registration. Still deferred from W6. |

---

## §11 — Sub-decisions Made Without Kevin's Input

The following calls were made by the spec author. Kevin should read and confirm before code starts. If any are wrong, update this spec before dispatch.

1. **ruleIndex mapping is fixed and permanent (§4.2).** The 15min preset maps to `r0` (not `r2`, which was the old 1h slot). This means after FT-6 ships, the old 1h request (previously `r0`) is superseded by the new 1h request at `r2`. There is a brief window between upgrade and the next pin-drop/settings-change where the old `r0` (1h) continues to exist alongside the new `r2` (1h) if both are scheduled. In practice this can't happen: the old `r0` fires and is consumed before the next park event. **Confirmed non-issue.** If Kevin wants to keep the 1h at `r0` for easier debugging, say so and the table in §4.2 can be renumbered (this would be a pure constant change; no behavior change).

2. **"Night before" body copy uses "tomorrow" unconditionally (§5.6).** If the night-before preset fires late enough that "tomorrow" is technically "today" (i.e. user parks at 11:30 PM for a midnight-adjacent restriction), the phrasing could be off. In practice, restrictions 5–12h away that also have a valid night-before time are rare at 11:30 PM — and if they occur, "tomorrow" is still approximately correct ("tomorrow morning at 7:00 AM"). This is an acceptable simplification.

3. **`SettingsView` takes `onOffsetsChange: @escaping () -> Void` (§6.2) rather than a direct `NotificationScheduler` reference.** This preserves the existing dependency-injection discipline: `SettingsView` has no direct reference to `NotificationScheduler`, `ParkPinService`, or `TileLoader`. `ContentView` owns the reschedule logic. Consistent with how `onUnmute` works today.

4. **No "at least one preset active" UI enforcement (§6.1).** A user who disables all five presets gets no notifications, which is equivalent to turning off `notifyOnRestriction`. This is intentional and requires no validation UI. If Kevin wants a warning, say so.

5. **`scheduleForTest` gets a new `offsets:` parameter (§5.7) rather than a separate `scheduleForTestWithOffsets(...)` method.** Keeps the test entry point unified. The `nil` default means the existing test call sites compile unchanged.
