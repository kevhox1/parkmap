# W6 — Local Notifications + Permission Flow

**Status:** Decisions locked 2026-05-13. Spec ready for `@ios-engineer` after Kevin closes the open questions below.
**Owner:** @ios-engineer (build), Tech Lead (spec).
**Depends on:** W5 + W5.1 merged to `main`. `ParkPinService.firstPinDropped` and `pinDropped` Combine hooks verified by QA (W5 QA pass-1 report at `docs/qa/w5-pass-1-2026-05-12.md`).
**Blocks:** W7 (ASP banner — needs to coexist with notification mute state); W7.5 ("Park Until X" filter — affects which restriction is the notification target, §4.3).
**Spec references:** `docs/ios-mvp-spec.md` §2.1 (notification fire time baseline), §3.4 (permission timing), §3.6 (rationale string); `docs/w5-pin-drop-spec.md` §6.1 (hook definition); `docs/w4-block-detail-spec.md` §3.4 (original cross-reference); `Services/Constants.swift` (rationale string storage); `Services/ParkPinService.swift` lines 33–35 and 39–41 (hook API).

---

## §0 — Open Questions for Kevin

These are binary decisions that cannot be resolved unilaterally. Read before dispatch. The spec is otherwise fully locked.

**OQ-W6-1: Lead time — 1 hour or 2 hours before restriction?**
`docs/ios-mvp-spec.md` §2.1 says: *"Fire time = (next ASP start - 1 hour)."* This is the original locked decision. The prompt asks to evaluate 2h as an alternative. 1h is tighter but more urgent; 2h gives more runway for someone who is not near their car. Recommendation: **keep 1h** — it matches the locked spec baseline, mirrors what a NYC parker actually needs (most people work or live within a few minutes of their car), and avoids waking someone up two hours before a 7am ASP when they would just be going back to sleep. Change only if you want to deviate from the §2.1 baseline. This question gates `NotificationScheduler.leadTimeSeconds` constant definition.

**OQ-W6-2: Single notification per restriction window, or two (lead-up + last-call)?**
A single notification at T-1h covers the daily-active user. A two-notification pattern (e.g., T-12h "heads-up" + T-1h "move now") benefits users who park and come back days later. The 64-notification-per-app iOS budget makes two-per-window viable only if the user has fewer than 32 upcoming restriction windows (safe in practice — most cars have at most 2 ASP windows per week). Recommendation: **single notification at the lead time** for v1.0. The two-notification pattern is a good v1.1 enhancement once TestFlight feedback tells us whether the 1h single notification is sufficient. If Kevin prefers two notifications now, say so and the spec will add a `secondLeadTimeSeconds` constant and a second `UNNotificationRequest` per window.

**OQ-W6-3: Notification tap behavior — deep-link to ParkedCarDetailView?**
When the user taps a delivered notification, the app opens. The question is whether to deep-link directly to `ParkedCarDetailView` (the car pin detail sheet) or just open the map. Deep-linking requires a `userInfo` payload in `UNNotificationContent` and a `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` implementation that routes to the right view. Recommendation: **implement the deep-link** — it is a two-step wiring job (encode pin ID in `userInfo`, handle in delegate) and the UX payoff is high (user taps notification, sees the pin detail with "I left" button immediately). If Kevin wants to defer and just open the map root, say so.

---

## §1 — User Story

A NYC street parker drops their car pin on Mott St (North side, ASP Mon/Thu 7–9:30am). It is Wednesday evening. The app computes that the next restriction is Thursday 7:00am — 9 hours from now. WePark schedules a local notification to fire at 6:00am Thursday (1 hour before ASP starts). The user locks their phone and goes to sleep. At 6:00am Thursday the notification appears on the lock screen: "Mott St (N) — Move your car by 7:00 AM. ASP starts in 1h." The user taps the notification, the app opens with `ParkedCarDetailView` visible, they confirm they need to move, and later clear the pin with "I left." If Thursday turns out to be an ASP suspension day, the notification was never scheduled in the first place — the engine already skips suspended dates in `computeHoursUntilASP`.

For a first-time user, the flow starts when they drop their first pin: a rationale sheet slides up explaining what notifications will do ("Get a reminder before alternate-side parking starts so you never get ticketed. Notifications are scheduled on-device only." — verbatim from `Services/Constants.swift:15`). They tap "Enable Reminders," iOS shows the system permission prompt, they allow it, and notifications are scheduled immediately for the current pin. If they deny, the sheet shows a one-time note with a Settings deep-link and the pin is saved without a notification.

Subsequent pins — replacements, Drive Mode arrivals, or any other source — silently cancel the previous notification set and schedule new ones without showing the rationale sheet again.

---

## §2 — Scope

### 2.1 In scope

- `Services/NotificationScheduler.swift` — new file. All scheduling logic: compute fire date from `NextRestriction`, build `UNNotificationContent` and `UNNotificationRequest`, add to `UNUserNotificationCenter`, cancel by identifier prefix.
- Rationale sheet (`Views/NotificationRationaleView.swift` — new file). Shown once on first pin drop. Three states: pre-request, permission-granted confirmation, permission-denied with Settings deep-link.
- Permission request flow: `UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound, .badge])` called from the rationale sheet's "Enable Reminders" button.
- `ContentView` wiring: `.onReceive(parkPinService.firstPinDropped)` → show rationale sheet; `.onReceive(parkPinService.pinDropped)` → schedule notifications.
- Notification identifier scheme (`wepark.pin.<carID>.r<ruleIndex>` — §3.5).
- Cancellation on `clearPin()` and on new pin drop (cancel-then-reschedule).
- Notification tap deep-link to `ParkedCarDetailView` via `UNUserNotificationCenterDelegate` and `AppDelegate` (or SwiftUI `UNUserNotificationCenterDelegate` shim — §3.7).
- `UserDefaults` flag `wepark_notification_rationale_shown` — gates rationale sheet to exactly one appearance per install.
- Edge-case handling: no nearby segment (nil), bare FREE segment, metered-only block, next restriction > 14 days, ASP suspension, active-restriction-at-pin-time (§3.6).

### 2.2 Out of scope — do NOT build

- **W7 mute toggle.** W7 builds the settings sheet and the mute `UserDefaults` flag. W6 leaves a clean integration point (§4.1).
- **W7.5 "Park Until X" notification adjustment.** W7.5 may shift the relevant target restriction. W6 ignores `parkUntilTime` entirely and always schedules for the soonest restriction from the engine. Integration point in §4.3.
- **Multiple notifications per window** (lead-up + last-call). Deferred pending OQ-W6-2 resolution. If Kevin answers "yes to two," amend §3.3 before dispatch.
- **Notification actions** (snooze button in the notification banner). Snooze would require a `UNNotificationAction` and a category registration. V1.1 enhancement if TestFlight feedback requests it.
- **Remote push / APNs.** Local-only. No server involvement. Explicitly confirmed in `docs/ios-mvp-spec.md` §2.2.
- **Settings screen.** W7. W6 produces no settings UI.
- **Notification for metered blocks.** The engine skips METERED in `nextRestriction(for:at:)` — the Swift port is explicit at `ParkingRulesEngine.swift:194`. Metered notifications are therefore undefined at the engine level. No metered notifications in W6. (See §3.6 edge cases for more detail.)
- **Badge count management beyond the initial schedule.** iOS delivers the badge automatically from the notification payload. W6 does not implement badge-clearing logic. That can be added in the settings polish pass.

---

## §3 — Detailed Behavior

### 3.1 Rationale Sheet

**Trigger:** `ContentView` receives `parkPinService.firstPinDropped` via `.onReceive`. Before showing the sheet, check `UserDefaults.standard.bool(forKey: "wepark_notification_rationale_shown")`. If `true`, skip the sheet entirely (belt-and-suspenders guard in case `hasEverParkedKey` semantics ever drift). If `false`, present `NotificationRationaleView` as a `.sheet(isPresented:)`.

**Sheet style:** `.presentationDetents([.medium])`. `.interactiveDismissDisabled(true)` — the user must tap a button to dismiss; accidental swipe-away skips the permission request entirely, which is a bad default.

**Sheet content (pre-request state):**

1. SF Symbol icon: `bell.badge.fill`, `.font(.system(size: 48))`, `Color.orange` (palette `ParkingColors.restrictionComingSoon` — warning-state orange is semantically appropriate for "pay attention to this reminder").
2. Title: `"Stay ahead of street cleaning"`, `.title2.bold()`.
3. Body: `AppConstants.notificationRationale` — *"Get a reminder before alternate-side parking starts so you never get ticketed. Notifications are scheduled on-device only."* Font `.body`. `.multilineTextAlignment(.center)`.
4. "Enable Reminders" button — `.buttonStyle(.borderedProminent)`. On tap: call `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])`. Await the result. On granted: set `wepark_notification_rationale_shown = true`, dismiss sheet, immediately schedule notifications for `parkPinService.parkedCar` (the just-dropped pin). On denied: transition to the denied state within the same sheet (do not dismiss).
5. "Not now" button — `.buttonStyle(.bordered)`, `.foregroundStyle(.secondary)`. On tap: set `wepark_notification_rationale_shown = true`, dismiss sheet. No notifications scheduled. No guilt-trip messaging.

**Sheet content (denied state, shown after system prompt returns .denied):**

1. SF Symbol icon: `bell.slash.fill`, `.font(.system(size: 48))`, `Color.gray`.
2. Title: `"Reminders are off"`, `.title2.bold()`.
3. Body: `"To get parking reminders, enable notifications for WePark in Settings."` Font `.body`. `.multilineTextAlignment(.center)`.
4. "Open Settings" button — `.buttonStyle(.borderedProminent)`. On tap: `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`. This is a standard Settings deep-link; iOS opens the app's Settings page directly.
5. "Done" button — `.buttonStyle(.bordered)`. Dismisses sheet.

**Sheet content (granted confirmation — optional):**
No separate confirmation state is needed. The sheet dismisses on grant, and the scheduled notification is the implicit confirmation. Keep it simple.

**Accessibility:** Sheet title is the first focusable element (`.accessibilityAddTraits(.isHeader)`). "Enable Reminders" button: `.accessibilityLabel("Enable parking reminders")`. "Not now": `.accessibilityLabel("Skip, do not enable reminders now")`. "Open Settings": `.accessibilityLabel("Open WePark in iOS Settings to enable notifications")`.

### 3.2 Permission Checking on Subsequent Launches

W6 does NOT call `requestAuthorization` on subsequent launches. The only trigger is the rationale sheet. However, `NotificationScheduler.schedule(for:)` must call `UNUserNotificationCenter.current().getNotificationSettings { settings in ... }` before scheduling to guard against the case where the user granted permission during rationale, then later disabled it in iOS Settings. If `settings.authorizationStatus == .denied`, skip scheduling silently. The app does not re-prompt or show an in-app warning in W6 — that is a W7 settings-sheet concern (§4.1).

### 3.3 Scheduling Logic

The scheduling function in `NotificationScheduler` takes a `ParkedCar` and the current `Date`. It:

1. Resolves `detectedSegmentID` to a `Segment` via `TileLoader` or the engine's loaded segments. If nil or not found, no notification is scheduled (§3.6 edge case: no nearby segment).

2. Calls `engine.nextRestriction(for: segment, at: now)` to compute the next restriction.

3. If `restriction.isUnrestricted` (`hours >= 168`): no notification. Silent return.

4. If `restriction.isActiveNow` (`hours == 0`): the pin was dropped during an active restriction. No future notification target can be computed from `hours` alone — the next window is `one full period away`. The spec recommendation is: **no notification in this edge case**. The user parked during an active restriction (likely they're aware — they just parked there). The next window will be days away; schedule nothing and let the map colors guide them. This matches the JS behavior where a `hours == 0` result in the notification path would produce a fire-date in the past.

5. Compute fire date: `fireDate = now + (restriction.hours * 3600) - leadTimeSeconds`. Where `leadTimeSeconds = 1 * 3600` (1 hour, per `ios-mvp-spec.md` §2.1 baseline — or `leadTimeSeconds = OQ-W6-1 answer * 3600`).

6. If `fireDate <= now`: the lead time window has already passed (e.g., pin dropped at 6:30am for a 7:00am ASP — 30 min away is less than the 1h lead time). **Do not schedule a notification in the past.** Silent return. The user is presumably already aware they are close to a restriction.

7. Build `UNMutableNotificationContent` per §3.4.

8. Build `UNCalendarNotificationTrigger` from `fireDate` via `Calendar.easternTime.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)`. Using `UNCalendarNotificationTrigger` (not `UNTimeIntervalNotificationTrigger`) ensures the notification fires at the correct wall-clock time even if the device clock shifts (e.g., DST transition). `repeats: false`.

9. Create `UNNotificationRequest(identifier: notificationID(for: car, ruleIndex: 0), content: content, trigger: trigger)`.

10. Add to `UNUserNotificationCenter.current().add(request)`.

All scheduling is dispatched to a background queue for the `UNUserNotificationCenter` call (the completion handler pattern is callback-based; the main-thread scheduling call itself is fast). The engine computation in step 2 must happen on the main thread (it accesses `TileLoader.loadedSegments` which is `@MainActor`-bound per W2 architecture).

**Lead time constant:**

```
// Services/NotificationScheduler.swift
static let leadTimeSeconds: TimeInterval = 1 * 3600   // 1h — ios-mvp-spec §2.1
```

This is the only constant the engineer needs to change if Kevin answers OQ-W6-1 with "2h."

### 3.4 Notification Content

**Title (≤50 chars, critical info first):**

Format: `"Move your car — <street> (<side>)"`
Examples:
- `"Move your car — Mott St (N)"`
- `"Move your car — 1st Ave (W)"`

Rationale: "Move your car" as the imperative opens the title. Street + side is the where. The total is ≤35 characters in most cases, well within iOS's ~50-character lock-screen title display.

**Body (≤80 chars):**

Format: `"<restriction label> starts <time label>. Move by <time>."`
Examples:
- `"ASP Mon/Thu starts in 1h at 7:00 AM. Move by 7 AM."`
- `"No Parking starts Today at 8:00 AM. Move by 8 AM."`

The `<restriction label>` comes from `NextRestriction.label` (e.g., "ASP Mon/Thu", "No Parking"). The `<time label>` comes from `ParkingRulesEngine.nextRestrictionTimeLabel(hours:now:)` (already implemented — returns "Today 7:00 AM", "Tomorrow 9:30 AM", "Thursday 7:00 AM"). The `"Move by <time>"` suffix repeats the deadline clearly since the title and body may be read separately on the lock screen.

**Subtitle:** Omit. The two-line title + body format is already information-dense. A subtitle would crowd the notification and is not displayed on the Dynamic Island or CarPlay.

**Sound:** `UNNotificationSound.default`. No custom sound.

**Badge:** Set `badge = 1` on the notification content so the app icon shows a badge. This is a reminder application — a badge is appropriate and expected.

**`userInfo` dict (for deep-link, OQ-W6-3):**

```
content.userInfo = [
    "wepark_car_id": car.id.uuidString,
    "wepark_action": "show_car_detail"
]
```

The `UNUserNotificationCenterDelegate` handler reads `wepark_action` to route to `ParkedCarDetailView` (§3.7).

### 3.5 Notification Identifier Scheme

Each `UNNotificationRequest` uses a stable, predictable identifier so cancellation is precise:

```
wepark.pin.<car.id.uuidString>.r0
```

For a single-notification-per-window design (OQ-W6-2 = single): only `r0` exists. The `r` index is reserved for a future two-notification design where `r0` is the lead notification and `r1` would be a "heads-up" notification at a longer offset. This way the identifier scheme is forward-compatible without a breaking change.

**Cancellation by prefix:** `UNUserNotificationCenter.current().getPendingNotificationRequests { requests in ... }` then filter by `identifier.hasPrefix("wepark.pin.\(car.id.uuidString)")` and pass to `removePendingNotificationRequests(withIdentifiers:)`. This cancels all of a given pin's notifications regardless of how many exist.

The car `id` is a `UUID` stored in `ParkedCar.id` (`Models/ParkedCar.swift`). Because `ParkedCar` uses a stable `id` (created once at pin drop and persisted in `UserDefaults`), the identifier is stable across app restarts — the same notification can be found and cancelled from any execution context.

### 3.6 Edge Cases

**No nearby segment (`detectedSegmentID` is nil):** `NotificationScheduler.schedule(for:)` receives a `ParkedCar` with `detectedSegmentID == nil`. Skip scheduling immediately. No notification. No user-facing indicator. The pin was saved successfully; the user just won't get a reminder. This matches the pin fallback behavior established in W5 §2.1.

**Bare FREE segment (segment has no rules, or all rules return `hours >= 168`):** `engine.nextRestriction(...)` returns `isUnrestricted == true`. No notification. Silent. Correct behavior — there is nothing to remind the user about.

**Metered-only block (segment's only rules are METERED):** `ParkingRulesEngine.nextRestriction` explicitly skips METERED rules (mirrors `index.html:5365`). Returns `hours == 168`. No notification. This is correct — metered blocks are a "pay or get ticketed" situation, not a "move your car" situation. The user is managing meter time themselves.

**Next restriction more than 14 days away:** The engine caps its walk at 14 days (168 hours). If `hours >= 168`, `isUnrestricted == true`. No notification. If the restriction is 7–13 days away, `hours` will be in `[0, 168)` and a notification will be scheduled normally. iOS persists scheduled `UNNotificationRequest`s across app kills and even reboots, so a notification scheduled for 7 days from now will still fire.

**Next restriction on an ASP-suspended date:** `ParkingRulesEngine.computeHoursUntilASP` already skips suspended dates when walking the 14-day window (per W3 spec and parity tests). The `hours` value returned to the scheduler already reflects the skip. W6 gets the correct post-suspension fire date automatically, with no additional suspension logic needed in `NotificationScheduler`.

**Pin dropped during active restriction (`hours == 0`):** No notification scheduled (see §3.3 step 4). The map polyline is red, which is the appropriate visual signal.

**Pin dropped with less than `leadTimeSeconds` until restriction:** `fireDate <= now`. No notification. User is already within the lead window — they are presumably aware.

**Pin dropped at 2am for 7am same-day ASP (5h away, 1h lead time):** `fireDate = 2am + 5h - 1h = 6am`. `fireDate > now`. Notification scheduled for 6am. Correct.

**User disables notifications in iOS Settings after granting:** `getNotificationSettings` returns `.denied` at next `schedule(for:)` call. W6 silently skips scheduling. The pin is saved, no notification fires, no in-app indicator shown. The W7 settings sheet will surface the "notifications off" state for the user to act on (§4.1).

**App killed when notification fires:** iOS delivers the notification regardless — `UNNotificationRequest`s persisted by the OS are independent of the app process. No special handling needed.

**"I left" clear flow:** `ParkPinService.clearPin()` calls `NotificationScheduler.cancelAll(for:)`. `cancelAll` removes all pending `UNNotificationRequest`s whose identifier starts with `"wepark.pin.\(car.id.uuidString)"`. Also removes delivered notifications from Notification Center for the same identifiers via `UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:)`. This keeps Notification Center clean after the user confirms they have moved.

**New pin replaces existing pin (silent replace):** `ParkPinService.save(_:)` → `pinDropped` fires → `ContentView` (or a dedicated observer, §3.8) calls `NotificationScheduler.cancelAll(for: oldCar)` then `NotificationScheduler.schedule(for: newCar)`. The old car ID is available from `parkPinService.parkedCar` before the save overwrites it. The ordering must be: (1) capture old car ID, (2) save new pin (writes `parkedCar`), (3) cancel old notifications, (4) schedule new. `ParkPinService.save(_:)` fires `pinDropped` after writing (per W5.1 fix — `pinDropped.send(car)` is inside the do-catch block). The observer in `ContentView` receives the new car; it should also read the old car before any save begins. Implementation note for the engineer: `ContentView` should capture `parkPinService.parkedCar` at the start of the `onReceive(pinDropped)` handler (the old value), before the handler body runs the cancel-then-schedule logic. The `@Observable` property updates atomically on the main actor.

### 3.7 Notification Tap Deep-Link

**AppDelegate approach (recommended for W6):**

Add a minimal `AppDelegate` (if one does not exist — check `WePark.swift` for `@main`) that conforms to `UNUserNotificationCenterDelegate`. Alternatively, in a SwiftUI `@main` App struct, add a `UNUserNotificationCenterDelegate` shim via `@UIApplicationDelegateAdaptor`.

In `userNotificationCenter(_:didReceive:withCompletionHandler:)`:

1. Extract `userInfo["wepark_action"]` and `userInfo["wepark_car_id"]`.
2. If action is `"show_car_detail"` and car ID matches `parkPinService.parkedCar?.id.uuidString`: set a `@State` or environment flag that triggers `ParkedCarDetailView` presentation in `ContentView`.
3. Call `completionHandler()`.

The flag can be a simple `@Published var shouldShowParkedCarDetail: Bool` on `ParkPinService` or a separate `AppRouter` object. Engineer's choice on the routing mechanism — the spec only constrains the outcome (tapping the notification opens `ParkedCarDetailView`).

**`UNUserNotificationCenter.current().delegate`** must be set before the app finishes launching (in `application(_:didFinishLaunchingWithOptions:)` or the App struct `init()`). iOS silently drops delegate calls if this is not set.

### 3.8 ContentView Wiring

`ContentView` gains two new `.onReceive` subscriptions:

```
// W6 hook — first pin: show rationale sheet
.onReceive(parkPinService.firstPinDropped) {
    if !UserDefaults.standard.bool(forKey: "wepark_notification_rationale_shown") {
        showNotificationRationale = true
    }
}

// W6 + W7.5 hook — every pin: cancel old notifications, schedule new
.onReceive(parkPinService.pinDropped) { newCar in
    // Capture old car before state update (oldCar is already updated at this point;
    // engineer must read old ID from a pre-saved local var — see §3.6 replace note)
    Task { @MainActor in
        await NotificationScheduler.shared.cancelAllThenSchedule(for: newCar)
    }
}
```

`@State var showNotificationRationale: Bool = false` drives the `NotificationRationaleView` sheet.

**Do not** observe `firstPinDropped` in more than one place. The sheet logic lives in `ContentView` only.

---

## §4 — Cross-Cutting Integration

### 4.1 W7 Mute Toggle Integration Point

W7 will add a mute toggle in a settings sheet, persisted at `UserDefaults.standard.bool(forKey: "wepark_notifications_muted")`. W6 must leave this key reserved but not read it (W7 defines its semantics). The clean hook for W7:

In `NotificationScheduler.schedule(for:)`, add a guard before scheduling:

```
// W7 integration point — mute check
// W7 writes "wepark_notifications_muted" = true when the user mutes.
// W6 stubs this as always false; W7 fills it in.
guard !UserDefaults.standard.bool(forKey: "wepark_notifications_muted") else { return }
```

This guard is a no-op in W6 (key is absent = false), and W7 can activate it by writing the key without touching `NotificationScheduler`. No W6 rework required when W7 ships.

### 4.2 W7 ASP Banner Co-Existence

The ASP banner (W7) and the notification system (W6) both read from `ParkingRulesEngine` and `ASPSuspensionService`. They are independent consumers — no shared state, no collision risk. The W7 banner shows today's suspension status as a visual element; W6 schedules future reminders. They can be built and merged in either order.

### 4.3 W7.5 "Park Until X" Notification Target Shift

When W7.5 ships, the user may select a "park until" time (e.g., "I'm leaving at 5pm"). If the first upcoming restriction is after 5pm, the user does not need a notification. W6 does not implement this logic. The integration point: `NotificationScheduler.schedule(for:parkUntil:)` — add a `parkUntil: Date?` parameter, defaulting to `nil`. When non-nil and `fireDate > parkUntil`, skip scheduling. W7.5 will call the updated signature; W6 ships with `parkUntil: nil` always.

### 4.4 Drive Mode Arrival (W8.5/W9)

Drive Mode's arrival flow will drop a pin via `ParkPinService.save(_:)`, which fires `pinDropped`. `ContentView` observes `pinDropped` and calls `NotificationScheduler.cancelAllThenSchedule(for:)`. The source of the pin drop (manual long-press vs Drive Mode arrival) is irrelevant to W6 — the notification scheduling path is identical. No special Drive Mode handling in `NotificationScheduler`.

---

## §5 — Test Plan

### 5.1 Unit tests (`WeParkTests/NotificationSchedulerTests.swift` — new file)

All tests use a mock `UNUserNotificationCenter` subclass or dependency-injected protocol to avoid requiring actual notification permission in the test environment.

| Test ID | Description | Expected result |
|---|---|---|
| T-W6.1 | `schedule(for:)` with a segment whose next restriction is 3h away, lead time 1h | One `UNNotificationRequest` scheduled with `fireDate` ≈ `now + 2h`. Identifier matches `"wepark.pin.<id>.r0"` scheme. |
| T-W6.2 | `schedule(for:)` with `detectedSegmentID = nil` | No request added to notification center. |
| T-W6.3 | `schedule(for:)` with bare FREE segment (hours >= 168) | No request added. |
| T-W6.4 | `schedule(for:)` with metered-only segment | `nextRestriction` returns `hours = 168`. No request added. |
| T-W6.5 | `schedule(for:)` with restriction 45min away, lead time 1h | `fireDate <= now`. No request added. |
| T-W6.6 | `schedule(for:)` with restriction active now (hours = 0) | No request added. |
| T-W6.7 | `cancelAll(for:)` when one request exists | The request is removed from the pending list. |
| T-W6.8 | `cancelAll(for:)` with a different car ID | Correct request removed; unrelated requests untouched. |
| T-W6.9 | Notification content: title format | Title matches `"Move your car — <street> (<side>)"` format exactly. |
| T-W6.10 | Notification content: body format | Body contains restriction label and time label. |
| T-W6.11 | `schedule(for:)` with ASP suspension on the restriction day | `nextRestriction` skips the suspended day; fire date is past the suspension. The engine's parity tests (already at 45/0) cover the hours computation. This test verifies the scheduler uses the hours value faithfully. |
| T-W6.12 | `UserDefaults` flag `wepark_notification_rationale_shown` gating | Rationale sheet is not shown on second `firstPinDropped` emission when flag is true. |

### 5.2 Simulator / device tests

These cannot be automated as unit tests; run manually during QA.

| Test ID | Description | How to verify |
|---|---|---|
| ST-W6.1 | Full rationale flow — first pin, permission granted | Drop pin (clean `UserDefaults` state). Rationale sheet appears. Tap "Enable Reminders." System prompt appears. Grant. Sheet dismisses. Check `UNUserNotificationCenter.current().getPendingNotificationRequests` in a debug breakpoint — one request present. |
| ST-W6.2 | Full rationale flow — first pin, permission denied | Same as ST-W6.1 but deny at system prompt. Sheet transitions to denied state. "Open Settings" button opens iOS Settings. No pending notification requests. |
| ST-W6.3 | Rationale shown only once | Drop second pin after ST-W6.1. Rationale sheet does not appear. `wepark_notification_rationale_shown = true` in `UserDefaults`. |
| ST-W6.4 | Notification fires while app is backgrounded | Schedule a notification with a 30-second lead time (temporarily lower `leadTimeSeconds` constant). Background the app. Wait 30 seconds. Notification appears on lock screen. |
| ST-W6.5 | Notification fires while app is killed | Same as ST-W6.4 but kill the app (swipe up in app switcher). Notification still fires. |
| ST-W6.6 | Notification tap deep-links to ParkedCarDetailView | Tap the notification from ST-W6.4 or ST-W6.5. App opens. `ParkedCarDetailView` is presented over the map immediately. |
| ST-W6.7 | "I left" cancels notifications | Drop pin, grant permission, verify notification scheduled (debug breakpoint). Tap pin → "I left." Check `getPendingNotificationRequests` — zero results for this car's identifier prefix. |
| ST-W6.8 | New pin cancels old notifications | Drop pin A, verify request A scheduled. Drop pin B. Verify request A is gone and request B is present. |
| ST-W6.9 | No notification for no-nearby-data pin | Long-press in Hudson River (no segment). Rationale sheet shows (first pin), permission granted. Zero pending notification requests. |
| ST-W6.10 | Notification content correctness on lock screen | With a near-future scheduled notification, lock device and let it fire. Read lock-screen banner. Title and body match §3.4 format. |

---

## §6 — Acceptance Criteria

- [ ] **AC-W6.1 — Rationale sheet appears on first pin.** Drop a first pin (clean `UserDefaults`: no `wepark_has_ever_parked`, no `wepark_notification_rationale_shown`). `NotificationRationaleView` sheet appears before the pin annotation is visible on the map. (The rationale fires from `firstPinDropped`, which fires before `pinDropped` in `ParkPinService.save` — see `ParkPinService.swift:65-67`.)
- [ ] **AC-W6.2 — Rationale sheet appears exactly once.** Drop a second, third, and fourth pin over multiple app sessions. Rationale sheet does not appear. `wepark_notification_rationale_shown = true` in `UserDefaults` in all cases.
- [ ] **AC-W6.3 — Permission request path.** From the rationale sheet, "Enable Reminders" triggers the iOS system permission prompt. Granting permission: sheet dismisses, `wepark_notification_rationale_shown = true`, notification scheduled for current pin. Denying permission: denied state shown within the same sheet, no crash, no notification scheduled.
- [ ] **AC-W6.4 — "Not now" path.** Tapping "Not now" on the rationale sheet: sheet dismisses, `wepark_notification_rationale_shown = true`, no notification scheduled, pin is saved normally (no regression to W5 pin drop).
- [ ] **AC-W6.5 — "Open Settings" deep-link.** From denied state, "Open Settings" opens iOS Settings to WePark's settings page. No crash on any tested device/simulator.
- [ ] **AC-W6.6 — Notification scheduled for ASP block.** Drop a pin on a block with an upcoming ASP restriction (e.g., ASP Mon/Thu with next window in 2–12h). Verify via `UNUserNotificationCenter.current().getPendingNotificationRequests` in a debug log: one request present with identifier matching `"wepark.pin.<carID>.r0"`. Fire time is `now + hours - 1h` within 1 minute of expected (rounding from `Double` hours).
- [ ] **AC-W6.7 — No notification for free/metered/nil blocks.** Drop a pin at (a) a bare FREE block, (b) a metered-only block, (c) a location with no nearby segment. In all three cases: zero pending notification requests after pin drop (permission already granted from a prior session).
- [ ] **AC-W6.8 — Lead-time-passed edge case.** Drop a pin when the next restriction is less than 1 hour away. Zero pending notification requests.
- [ ] **AC-W6.9 — Notification content matches spec.** Lock screen notification shows: title `"Move your car — <street> (<side>)"`, body contains the restriction label and a time reference (e.g., "ASP Mon/Thu starts in 1h at 7:00 AM"). Verify on at least 3 different block types.
- [ ] **AC-W6.10 — Notification fires while app is killed.** Drop pin with a 30-second test notification (temporarily adjust lead time). Kill app. Notification fires on schedule. App is not required to be running.
- [ ] **AC-W6.11 — Notification tap deep-links to ParkedCarDetailView.** Tapping the notification opens the app with `ParkedCarDetailView` presented. The correct car's data is shown. Applies whether app was backgrounded or killed.
- [ ] **AC-W6.12 — "I left" cancels notification.** After dropping a pin with a scheduled notification, tap the pin, tap "I left." Zero pending notification requests for that car's identifier prefix. Zero delivered notifications for that identifier in Notification Center.
- [ ] **AC-W6.13 — New pin cancels old notifications.** Drop pin A. Verify notification request A present. Drop pin B. Verify request A is absent and request B is present. Only one pending notification at a time.
- [ ] **AC-W6.14 — ASP suspension respected.** Drop a pin on a block whose next ASP window is a suspended date. The scheduled notification's fire time is past the suspension (i.e., the engine skipped it). Verify by checking the trigger date in the pending request.
- [ ] **AC-W6.15 — W7 mute stub is a no-op.** `wepark_notifications_muted` key absent from `UserDefaults` by default. Notifications schedule normally. Setting `wepark_notifications_muted = true` manually (via lldb or debug menu) causes `schedule(for:)` to skip scheduling — verifying the W7 hook fires correctly when the key is present.
- [ ] **AC-W6.16 — No W5 regression.** Pin drop, "I left" clear, persistence across launch, silent replace, and "Wrong street?" alternatives all work as per W5 ACs. `xcodebuild test` reports **45 passed, 0 failed** (W4.5 baseline). No new test failures introduced.
- [ ] **AC-W6.17 — No `Calendar.current` use.** QA verifies zero `Calendar.current` references in any new W6 file. All time math uses `Calendar.easternTime` (W3 invariant).
- [ ] **AC-W6.18 — `UNUserNotificationCenter.delegate` set at launch.** `UNUserNotificationCenter.current().delegate` is non-nil by the time the app finishes launching. Verify via breakpoint in the delegate's `willPresent` method — it fires when a notification is delivered while the app is in the foreground.
- [ ] **AC-W6.19 — Accessibility.** VoiceOver: (a) Rationale sheet title is first focusable element. (b) "Enable Reminders" reads "Enable parking reminders". (c) "Not now" reads "Skip, do not enable reminders now". (d) In denied state, "Open Settings" reads "Open WePark in iOS Settings to enable notifications".

---

## §7 — Implementation Surface

### New files

| File | Role | Estimated LOC |
|---|---|---|
| `Services/NotificationScheduler.swift` | All scheduling, cancellation, content building. Singleton (`shared`) or injectable class. | ~150 |
| `Views/NotificationRationaleView.swift` | Rationale sheet UI. Three states: pre-request, denied, (no granted state needed). | ~100 |

### Modified files

| File | Change | Estimated LOC delta |
|---|---|---|
| `ContentView.swift` | Add `@State var showNotificationRationale: Bool`. Add `.onReceive(firstPinDropped)` and `.onReceive(pinDropped)` subscriptions. Add `.sheet(isPresented: $showNotificationRationale)` for `NotificationRationaleView`. | +30 |
| `WePark.swift` (or `AppDelegate.swift`) | Add `UNUserNotificationCenterDelegate` conformance. Set `UNUserNotificationCenter.current().delegate = self` at launch. Implement `userNotificationCenter(_:didReceive:)` for tap deep-link. | +40 |
| `Services/Constants.swift` | Add `notificationRationaleShownKey`, `notificationsMutedKey` (W7 stub), `notificationLeadTimeSeconds` constants. | +5 |

**Total new LOC:** ~325. Tests: ~80 additional lines in `WeParkTests/NotificationSchedulerTests.swift`.

### Files NOT touched (confirmed)

- `Services/ParkingRulesEngine.swift` — read-only consumer. No changes.
- `Services/ParkPinService.swift` — hooks already in place. No changes in W6.
- `Models/ParkedCar.swift` — unchanged.
- `Views/BlockDetailView.swift`, `Views/ParkedCarDetailView.swift` — unchanged (ParkedCarDetailView presentation is triggered by notification tap via AppDelegate/delegate, not by changes to the view itself).
- `index.html` — maintenance mode. No changes.

---

## §8 — Effort + Sequence

### Engineer sessions

| Session | Work | Output |
|---|---|---|
| Session 1 (~2h) | `NotificationScheduler.swift`: scheduling, cancellation, content, identifier scheme. Unit tests for scheduling logic. No UI yet. | `NotificationSchedulerTests` passing (T-W6.1 through T-W6.12). |
| Session 2 (~1.5h) | `NotificationRationaleView.swift`. `AppDelegate`/`UNUserNotificationCenterDelegate` delegate shim. `ContentView.swift` wiring (two `.onReceive` subscriptions + sheet presentation). | Rationale sheet functional end-to-end in simulator. ST-W6.1 through ST-W6.3 can be self-verified. |
| Session 3 (~0.5h) | ST-W6.4 through ST-W6.10 self-pass. Fix any issues. AC self-verification. | PR-ready build. |

**Total: 2–3 sessions (4–5 hours active engineering).**

The split is: data layer (Session 1) then UI + wiring (Session 2) — same pattern used successfully in W5. Session 1 can begin as soon as the spec is dispatched. Session 2 depends on Session 1's `NotificationScheduler` API being stable.

### Where this sits in the Phase 5 backlog

```
W5.1 (polish, ~half session) → W6 (this spec, 2–3 sessions) → W7 (ASP banner) || W7.5 (Park Until X, post-W7)
```

W6 and W7 touch different files and can technically run in parallel. However W7's settings sheet may want to include a mute toggle that depends on W6's `wepark_notifications_muted` key being defined. Recommendation: run W6 first by one session, then start W7 in parallel once the `wepark_notifications_muted` key is defined in `Constants.swift`. This avoids a key naming collision.

### QA pattern

`@qa-verifier` files `docs/qa/w6-pass-1-<date>.md`. QA pass covers:
- AC-W6.1 through AC-W6.19.
- ST-W6.1 through ST-W6.10 (device/simulator tests).
- Confirms zero `Calendar.current` in new files.
- Confirms `UNUserNotificationCenter.delegate` set at launch (AC-W6.18).
- Confirms `wepark_notification_rationale_shown` is set on both the "Enable Reminders" path AND the "Not now" path (two separate branches in the UI that must both set the flag).
- Confirms `hasEverParkedKey` is NOT touched by `NotificationScheduler` — only `ParkPinService` sets it.
- Runs `xcodebuild test` and confirms 45 pass, 0 fail (plus any new W6 tests).

---

## §9 — Out-of-Scope Follow-Ups (punted with rationale)

**Snooze action in notification.** A `UNNotificationAction` "Snooze 30 min" button in the notification banner would let users delay the reminder without opening the app. This requires a `UNNotificationCategory` registration, an action handler, and a re-schedule. Useful but adds ~50 LOC and UI complexity. Defer to v1.1 — TestFlight will tell us if users want it.

**Two-notification-per-window pattern** (OQ-W6-2 deferred path). If Kevin answers "yes" to OQ-W6-2, the `NotificationScheduler` needs a second `UNNotificationRequest` at a longer offset (12h or 8h). The identifier scheme already reserves `r1` for this. The spec change is: add `secondLeadTimeSeconds: TimeInterval = 12 * 3600` constant and a second `schedule` call in `NotificationScheduler.schedule(for:)`. No other spec sections change.

**Badge clearing.** The `badge = 1` in the notification content increments the badge. After the user opens the app and sees their car detail, the badge should clear. `UIApplication.shared.applicationIconBadgeNumber = 0` in `applicationDidBecomeActive` or the `scenePhase.active` SwiftUI handler. Simple one-liner but not critical for W6 — defer to settings polish pass.

**"Notifications are off" in-app indicator.** If the user disables notifications post-grant, W6 silently skips scheduling (§3.2). W7's settings sheet will show this state explicitly. No in-app indicator in W6.

**Multiple restriction windows per pin.** The current spec schedules exactly one notification (for the nearest upcoming restriction). A block with, say, weekly ASP and a one-off NO PARKING event has two restrictions — W6 only notifies for the first one. Scheduling for the second window would require iterating `nextRestriction` calls forward in time, which is non-trivial with the current engine API (the engine is point-in-time, not windowed). Deferred. Not a gap for daily-active users whose pins are typically cleared within days.

**W7.5 "Park Until X" notification adjustment.** The `parkUntil: Date?` parameter is stubbed as `nil` in W6. W7.5 fills it in. No action needed in W6.

**2027 ASP calendar refresh.** The suspension data is hardcoded in `ASPSuspensionService` for 2026. Notifications that would fire in January 2027 will use stale suspension data. This is a known deferred item (HANDOFF.md backlog) — not a W6 concern.
