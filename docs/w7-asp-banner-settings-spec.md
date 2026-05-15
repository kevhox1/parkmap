# W7 — ASP Suspension Banner + Settings + Bundled UX Polish

**Status:** Spec locked 2026-05-15 (Kevin's decisions resolved). Ready for `@ios-engineer`.
**Owner:** @ios-engineer (build), Tech Lead (spec).
**Depends on:** W6 merged (PR #20). `ASPSuspensionService.suspensionState(at:)` and `AppConstants.notificationsMutedKey` are already live.
**Blocks:** W8 (TestFlight build).
**Spec reference:** `docs/ios-mvp-spec.md` §2.1, §3.7, §4.1; `docs/design/ios-mvp-palette.md` §3; `docs/w6-notifications-spec.md` (mute key stub).

---

## Resolved Decisions

**OQ-W7-1 (ToS / Privacy footer) — RESOLVED: omit from v1.**
Kevin confirmed he likes having legal links eventually but does not yet have hosted Terms or Privacy URLs or finalized copy. Decision: the Settings footer shows app version + build number only. Do not add a `termsURL` constant, do not add a conditional `Link` row, and do not use a placeholder URL. When Terms/Privacy copy and hosting are ready, that is a separate non-engineering task. A carry-over note will be added to `HANDOFF.md` once W7 ships (not part of this PR). The engineer should not add any ToS/Privacy affordance — even a commented-out one.

**OQ-W7-2 (mute-off confirmation) — RESOLVED: Toast-style banner.**
Kevin wants a Toast when the user flips global notifications from OFF back to ON. This overrides the earlier "toggle state is the confirmation" recommendation. A new reusable `ToastService` + `ToastHostView` primitive is designed as part of W7. See §3.E for the full spec. The Settings mute-off trigger is the first consumer; W7.5 and future flows will use the same primitive.

---

## 1. Problem and User Story

**A: ASP Suspension Banner.**
W6 introduced local notifications that fire before the next ASP restriction. But on a day when ASP is suspended, neither notifications nor block colors change to reflect the holiday — a user who opens the app on Memorial Day sees the same orange block they'd see on a Tuesday. The MVP spec (`docs/ios-mvp-spec.md` §2.1) calls for an "ASP suspension banner at the top of the map" with three states. W3 already shipped `ASPSuspensionService.suspensionState(at:)` for this purpose. W7 wires the view.

> I open WePark on Monday May 25. A red banner at the top of the map reads "ASP Suspended — Memorial Day." I don't worry about moving my car. No block-level detail needed; the banner is the answer.

**B: Settings Screen.**
The `AppConstants.notificationsMutedKey` UserDefaults key was stubbed in W6 (`NotificationScheduler.swift` line 100 — guard reads the key, but nothing in the UI writes it yet). The user has no way to globally silence reminders without revoking iOS permission, which is a heavy action they'd have to undo in iOS Settings. W7 provides the Settings sheet so the mute key becomes functional.

> I'm going on vacation; I don't want WePark reminders for two weeks. I tap the gear icon, flip "Park-reminder notifications" off, and done. When I'm back, I flip it on and the next pin drop schedules a reminder again.

**C: Per-Pin Reminder Toggle in ParkConfirmView.**
W6 always schedules a notification when the user drops a pin on an ASP block (subject only to the global mute). Kevin's W6 smoke feedback (`HANDOFF.md` "Carry-over deferrals"): *"different parking sessions have different urgency: overnight = want reminder; 30-min meeting = don't bother. Settings-level mute is too blunt."*

> I'm running into a coffee shop for 20 minutes. I drop a pin, the confirm sheet shows "Remind me before parking changes" toggled ON by default. I flip it OFF. No notification is scheduled. I don't have to touch Settings.

**D: Sign-Text Truncation Fix in BlockDetailView.**
Kevin caught during W5.1 smoke (`HANDOFF.md` "Carry-over deferrals"): rule descriptions like `"NO PARKING 8AM-6PM EXCEPT SUNDAY METERED PARKING 30 MIN MAX"` truncate to `"NO PARKING 8AM-6PM EXCEP..."` with no recovery. The `RuleRow` component in `BlockDetailView.swift` uses `.lineLimit(1)` with no expansion affordance.

---

## 2. Scope

### 2.1 In scope

- **`Views/ASPBanner.swift`** — new file. Three-state banner rendered via `ASPSuspensionService.suspensionState(at:)`. Positioned at the top of the map using `.safeAreaInset(edge: .top)` per the palette spec (`docs/design/ios-mvp-palette.md` §3). Not dismissible (see §3.A).
- **`Views/SettingsView.swift`** — new file. SwiftUI `Form` inside a `NavigationStack` inside a sheet. Entry point: gear icon (`gearshape.fill`) in the `ContentView` toolbar. Attached via a new `ActiveSheet.settings` case (see §4.C).
- **`ParkConfirmView.swift` — modified.** Add a `"Remind me before parking changes"` `Toggle` row. `defaults ON`. Persist the per-pin decision in a new `notifyOnRestriction: Bool` field in `ParkedCar`. `ParkPinService` passes this through to `NotificationScheduler`.
- **`NotificationScheduler.swift` — modified.** `schedule(for:)` reads the new `car.notifyOnRestriction` field and skips if false. No other scheduler logic changes.
- **`Models/ParkedCar.swift` — modified.** Add `notifyOnRestriction: Bool` field with a safe default. See §4.A for the persistence rationale.
- **`Views/ParkedCarDetailView.swift` — modified.** Add a toggle row below the "parked at" timestamp so the user can flip the reminder on or off after pin drop. Flipping writes back to `ParkPinService` and re-evaluates scheduling.
- **`Views/BlockDetailView.swift` / `RuleRow` — modified.** Tap-to-expand rule rows. See §3.D.
- **`AppConstants` — modified.** Add `settingsKey` constants for any new UserDefaults keys introduced by Settings (see §4.B). No `termsURL` constant — omitted per resolved OQ-W7-1.
- **`ContentView.swift` — modified.** Add gear toolbar button + `ActiveSheet.settings` case; add `.safeAreaInset(edge: .top)` for the ASP banner; add `onToggleMute` logic; embed `ToastHostView` in the root `ZStack`.
- **`Services/ToastService.swift`** — NEW. Singleton `@MainActor` observable that exposes `show(message:duration:)` and manages auto-dismiss. See §3.E.
- **`Views/ToastHostView.swift`** — NEW. SwiftUI view that reads `ToastService.shared` and renders the current toast (slide-down + fade). Lives in `ContentView`'s `ZStack`. See §3.E.

### 2.2 Out of scope (DO NOT BUILD)

- **"Tomorrow suspended" proactive notification.** The banner covers the tomorrow state visually; push notifications for tomorrow's suspension are post-MVP. Not in this PR.
- **ASP suspension banner dismissal.** Explicitly not dismissible (rationale in §3.A).
- **Second settings toggle (notifications for metered or other categories).** Confirmed deferred in `HANDOFF.md` — "Post-MVP — not a v1.0 priority since free parking is the core value prop."
- **StoreKit / Pro tier anything.** Not in MVP. `docs/business-model.md` is the reference.
- **About page.** A link-list about screen beyond the footer is out. Footer covers version + build number only (Terms/Privacy deferred per resolved OQ-W7-1), which is sufficient for App Store review.
- **Dark Mode palette tuning.** System semantic colors handle it automatically; no custom dark-hex work in W7.
- **W6.1 deep-link flake fix.** That carry-over is independent. Do not bundle.
- **W7.5 "Park Until X" filter.** Its own stream post-W7, pre-W8.

---

## 3. User-Facing Design

### 3.A: ASP Suspension Banner

**Placement.** The banner lives above the map content but below the iOS status bar. Use `.safeAreaInset(edge: .top)` on the `ZStack` that contains `MapViewRepresentable` — the exact approach prescribed in `docs/design/ios-mvp-palette.md` §3. This ensures the banner pushes the map content down rather than overlapping it. The find-me/find-my-car buttons in the top-right are not affected because they use `.padding(.top, 60)` relative to the `ZStack` — verify the constant remains large enough after the banner is inserted; if it clips the buttons, increase `60` to `60 + bannerHeight`.

**Three states — exact wording and colors.**

| State | Background | Text color | Wording |
|---|---|---|---|
| Today suspended | `Color.red` | `Color.white` | "ASP Suspended — [reason]" (e.g., "ASP Suspended — Memorial Day") |
| Tomorrow suspended | `Color(red: 0.92, green: 0.76, blue: 0.0)` (amber-yellow from `ParkingColors.meteredActive`) | `Color.black` | "ASP Suspended Tomorrow — [reason]" |
| ASP in effect | `Color.green` | `Color.white` | "ASP in Effect Today" |

Colors are taken directly from `docs/design/ios-mvp-palette.md` §3 and from `ParkingColors.swift`. Do not introduce new color constants.

**Dismissible: NO.** Rationale: the suspension status is a ground-truth safety fact that persists all day. An accidental swipe-away would leave the user without the one indicator that tells them not to bother moving their car. The PWA's `renderASPStatusBanner` has no dismiss control. Pattern follows Apple's own "Focus" pill and "Personal Hotspot" banner — persistent contextual system-level states are non-dismissible. A user who finds the banner distracting has misunderstood it; the informational text is brief and the banner height is small (~36pt content + vertical padding).

**Banner height.** Single-line `Text` at `.subheadline` weight, centered, with `12pt` vertical padding top and bottom. Total visual height ~40pt. The `.safeAreaInset` approach sizes to content — no fixed frame needed.

**Refresh cadence.** Read `ASPSuspensionService.suspensionState(at: .nowET)` once on view appear and on app foreground (`scenePhase` change to `.active`). The suspension calendar is date-based (days, not hours), so a 60-second timer recompute is unnecessary. A foreground-event refresh handles the midnight rollover correctly.

**Accessibility.** The banner is an always-visible `Text` element. Add `.accessibilityLabel("ASP \(stateLabel). \(reason)")` on the container so VoiceOver reads the full sentence rather than just the visible abbreviation. The banner should not be `accessibilityHidden`.

**Implementation note — `@Observable`.** `ASPBanner` is a pure view that calls `ASPSuspensionService` directly (the service is not `@Observable` by design — it is immutable after init, per its file header comment). Pass the service instance into `ASPBanner` as a `let` constant from `ContentView`. Compute `SuspensionBannerState` in a `@State` or computed property inside the view, refreshed via `.onAppear` and `.onChange(of: scenePhase)`.

### 3.B: Settings Sheet

**Entry point.** A gear icon button (`gearshape.fill`, SF Symbols) added to the `ContentView` toolbar. Placement: top-left of the map — opposite the existing find-me/find-my-car buttons in the top-right. Use `.toolbar` on the outermost `ZStack` or a `VStack` overlay — not a `NavigationView` toolbar (there is no `NavigationView` in `ContentView`). The simplest pattern: add a new `Button` in the `ZStack` positioned via `VStack { Spacer() }` alignment or a second `ZStack` overlay layer aligned `.topLeading`, with the same material-background pill style as the recenter buttons: `Image(systemName: "gearshape.fill")` in a 44×44 frame with `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))`.

**Presentation.** `.sheet(item: $activeSheet)` with a new `ActiveSheet.settings` case. Inside the sheet: `NavigationStack { Form { ... } }`. `.presentationDetents([.medium])`. `.presentationDragIndicator(.visible)`. `.presentationBackground(.regularMaterial)`.

**Sheet content — exactly two sections.**

**Section 1 — Notifications.**

```
Section("Notifications") {
    Toggle("Park-reminder notifications", isOn: $notificationsMuted.negated)
}
```

- The UserDefaults key is `AppConstants.notificationsMutedKey` ("wepark_notifications_muted"), already defined in `Constants.swift`.
- The toggle label reads "Park-reminder notifications" to be clear it only mutes WePark reminders, not iOS permission itself.
- The toggle state is the logical inverse of the stored `notificationsMuted` Bool — when `notificationsMuted == false` (key absent or false), the toggle reads ON (reminders are active). When `notificationsMuted == true`, toggle reads OFF.
- On toggle OFF (muting): write `true` to UserDefaults. Cancel all pending WePark notifications via `NotificationScheduler.shared.cancelAll(for: car)` if `parkPinService.parkedCar != nil`.
- On toggle ON (unmuting): write `false` to UserDefaults. If `parkPinService.parkedCar != nil` AND the car's `notifyOnRestriction == true`, call `NotificationScheduler.shared.schedule(for:loadedSegments:engine:)` to reschedule. This requires `ContentView` to pass `tileLoader.segments` and `engine` into `SettingsView`, or to handle the reschedule via a callback closure (recommended — see §4.B). After rescheduling, call `ToastService.shared.show(message: "Reminders re-enabled")` — this fires regardless of whether a pin exists, to avoid state-dependent copy variants (see §3.E).

**Section 2 — About.**

```
Section {
    HStack {
        Text("Version")
        Spacer()
        Text("\(appVersion) (\(buildNumber))")
            .foregroundStyle(.secondary)
    }
}
```

- `appVersion` is read from `Bundle.main.infoDictionary["CFBundleShortVersionString"]`.
- `buildNumber` is read from `Bundle.main.infoDictionary["CFBundleVersion"]`.
- Do NOT add a `termsURL` constant or a `Link` row. Terms/Privacy is deferred per resolved OQ-W7-1. When that content is ready it will be spec'd as a separate task; the engineer should not add any placeholder.

**No additional toggles.** The spec is intentionally minimal. "Notifications for metered blocks" and other settings are deferred per scope §2.2.

### 3.C: Per-Pin Reminder Toggle in ParkConfirmView

**Location in the sheet.** Add a `Toggle` row between the safety label and the action row in `ParkConfirmView`. Exact layout position:

```
1. Sheet title "Park my car"
2. Detected block section
3. "Wrong street?" alternatives (if any)
4. Safety label
5. [NEW] Reminder toggle
6. Action row (Cancel / Park here)
```

**Label.** "Remind me before parking changes" — exactly as Kevin described in HANDOFF. This phrasing is specific and actionable; it does not say "notifications" (which users associate with OS permission prompts).

**Default.** ON. The majority of park sessions are longer than 30 minutes; defaulting ON respects the overnight use case. A user who wants silence can flip it — one tap — before confirming. This is cheaper than requiring pro-active opt-in every time.

**State.** `@State private var remindMe: Bool = true` inside `ParkConfirmView`. It is not derived from any segment property or persisted preference — it starts fresh at ON for every pin-confirm session. Rationale: a user who turns it off for a coffee run should not have to remember to re-enable it next time.

**Propagation.** `ParkConfirmView.onConfirm` already receives the full `PinDropIntent`. W7 does not change `PinDropIntent`; instead, `onConfirm` receives a new second parameter: `notifyOnRestriction: Bool`. Alternatively — and cleaner — wrap both in a new `PinConfirmResult` struct. Recommended:

```swift
struct PinConfirmResult {
    let intent: PinDropIntent
    let notifyOnRestriction: Bool
}
```

`onConfirm: (PinConfirmResult) -> Void`. This keeps `PinDropIntent` unchanged and avoids leaking notification intent into the model layer. `ContentView.confirmPinDrop` reads `result.notifyOnRestriction` when constructing `ParkedCar`.

**Accessibility.** The toggle must have `.accessibilityLabel("Remind me before parking changes")` and `.accessibilityHint("When on, you'll get a notification before your parking window ends.")`.

### 3.D: Sign-Text Truncation Fix in BlockDetailView / RuleRow

**Current bug.** `RuleRow.body` renders `Text(rowText).lineLimit(1).truncationMode(.tail)` at `BlockDetailView.swift` lines 207-209. Long descriptions like `"NO PARKING 8AM-6PM EXCEPT SUNDAY METERED PARKING 30 MIN MAX"` truncate silently.

**Decision: tap-to-expand inline.** Not a chevron disclosure (which would require a second navigation level or a sheet). Rationale: a chevron navigates the user away from the context where they need the rule text. Inline expand is faster, needs no dismiss gesture, and matches the behavior of iOS Settings rows with long secondary text.

**Pattern.** Add `@State private var isExpanded: Bool = false` to `RuleRow`. Change `.lineLimit(1)` to `.lineLimit(isExpanded ? nil : 1)`. Wrap the `HStack` in a `Button` that flips `isExpanded`. Animate: `.animation(.easeInOut(duration: 0.18), value: isExpanded)`.

When expanded:
- The full text flows onto as many lines as needed.
- The category badge moves to a trailing position below the text (use a `VStack` instead of `HStack` when `isExpanded`), or if it fits, remains trailing. Use a `ViewBuilder` to switch layouts.
- No "show less" button required — tapping the row again collapses it.

**Accessibility.** The row's `.accessibilityElement(children: .combine)` stays. Add `.accessibilityHint(isExpanded ? "Tap to collapse." : "Tap to expand full sign text.")`.

**Scope constraint.** This change is isolated to `RuleRow` in `BlockDetailView.swift`. `ParkedCarDetailView.swift` also uses `RuleRow` (same struct, same file per `BlockDetailView.swift` line 201 "Internal (not private) so both views in the same module can access it") — the fix propagates there for free.

**No new tests required** for this change specifically — it is a pure presentation toggle with no data-model impact. The existing 60 tests cover `RuleRow` data logic; expansion state is view-only.

### 3.E: Toast Primitive — ToastService + ToastHostView

**Background.** Kevin resolved OQ-W7-2 in favor of a Toast-style banner for the mute-off confirmation. Rather than building a one-off solution inside `SettingsView`, W7 ships a reusable Toast primitive that W7.5 ("Park Until X" filter), tracker confirmations, pin-cleared feedback, and future flows can consume without modification.

**Design decisions.**

- Single-toast-at-a-time. A new `show(message:)` call replaces any toast currently visible. No queueing in v1 — the surface area is too small for concurrent toasts to be useful.
- Auto-dismiss after 3 seconds (default). The duration is a parameter so individual call sites can override if needed, but callers should default to the standard 3s.
- Animation: slide down from the top safe-area inset + fade in. Dismiss is fade out + slide up. Use `withAnimation(.easeInOut(duration: 0.25))` for both directions.
- Toast position: rendered ABOVE the ASP banner. Rationale: the banner is persistent contextual state; the toast is a transient action confirmation. Overlaying the banner briefly is acceptable and keeps the toast visually at the very top of the interactive surface — the natural place the eye expects a system-level acknowledgement. The toast is short-lived (3s) so it does not obscure the banner meaningfully.
- Accessibility: call `UIAccessibility.post(notification: .announcement, argument: message)` on appearance so VoiceOver reads the toast text even when VoiceOver focus is elsewhere.

**`ToastService.swift`** (new file in `Services/`).

```swift
@MainActor
@Observable
final class ToastService {
    static let shared = ToastService()
    private init() {}

    private(set) var currentMessage: String? = nil
    private var dismissTask: Task<Void, Never>?

    func show(message: String, duration: TimeInterval = 3.0) {
        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            currentMessage = message
        }
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                currentMessage = nil
            }
        }
    }
}
```

Key points for the engineer:
- `@Observable` (not `ObservableObject`) — consistent with W6's `@Observable` adoption throughout the app.
- `@MainActor` guarantees all mutation is on the main thread. Callers on the main thread call `show(message:)` directly; background callers use `await MainActor.run { ToastService.shared.show(...) }`.
- `dismissTask?.cancel()` on each `show` call ensures the previous auto-dismiss timer does not fire after a new toast replaces the old one.

**`ToastHostView.swift`** (new file in `Views/`).

```swift
struct ToastHostView: View {
    @State private var service = ToastService.shared

    var body: some View {
        if let message = service.currentMessage {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.82), in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
                .onAppear {
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: message
                    )
                }
        }
    }
}
```

**Placement in ContentView.** The `ToastHostView` is added inside the root `ZStack` in `ContentView.body`, at the top of the stack order (last child of the `ZStack` = highest layer). It should be pinned to the top via a `VStack { ToastHostView(); Spacer() }` with `.padding(.top, safeAreaTopInset)` so it clears the status bar. The exact inset can be read from `GeometryReader` or via the `.safeAreaInset(edge: .top)` modifier applied to a transparent proxy view — prefer the proxy approach to avoid an extra `GeometryReader` wrapper.

**W7 trigger — mute-off.** In the `onUnmute` callback in `ContentView` (see §4.B):

```swift
onUnmute: {
    // ... reschedule notification if needed ...
    ToastService.shared.show(message: "Reminders re-enabled")
}
```

Message copy: `"Reminders re-enabled"` — 19 characters, single-line, no scheduled-time detail. Does not vary based on whether a pin exists.

**Future callers.** W7.5 ("Park Until X" filter) and tracker confirmation flows call `ToastService.shared.show(message:)` from their own action sites. No changes to `ToastService` or `ToastHostView` are needed to support them.

---

## 4. Architecture

### 4.A: ParkedCar Model Change — notifyOnRestriction

Add one field to `Models/ParkedCar.swift`:

```swift
/// W7: Whether the user opted into a reminder notification for this specific parking session.
/// Defaults true (reminder active). Persisted so the user can flip it in ParkedCarDetailView
/// after pin drop without losing the setting across app relaunches.
let notifyOnRestriction: Bool
```

**Why persisted.** Kevin's HANDOFF note is explicit: "the user might park, decide they want a reminder after all, then need to flip the toggle from `ParkedCarDetailView`." A transient in-memory flag would be lost on app kill. Since `ParkedCar` is already Codable and stored in UserDefaults, adding one Bool is zero extra architecture.

**Default for existing persisted cars (migration).** `ParkedCar` is decoded by `JSONDecoder`. Add a `CodingKeys` enum and a custom `init(from:)` that defaults `notifyOnRestriction = true` when the key is absent in the stored JSON. This handles the one user (Kevin) who has a pre-W7 pin in UserDefaults without invalidating it.

```swift
// Safe decoding default — existing pins before W7 will get notifyOnRestriction = true.
notifyOnRestriction = try container.decodeIfPresent(Bool.self, forKey: .notifyOnRestriction) ?? true
```

**`ParkPinService.updateNotifyOnRestriction(_:for:)`.** Add a method to `ParkPinService` that loads the current `ParkedCar`, sets a new `notifyOnRestriction` value, and saves. This is the write path for the `ParkedCarDetailView` toggle. `ParkedCar` is a `struct` (value type), so "set a new value" means constructing a new struct with the updated field and re-persisting.

```swift
func updateNotifyOnRestriction(_ enabled: Bool) {
    guard var car = parkedCar else { return }
    car = ParkedCar(
        id: car.id,
        latitude: car.latitude,
        longitude: car.longitude,
        detectedSegmentID: car.detectedSegmentID,
        detectedSide: car.detectedSide,
        street: car.street,
        fromStreet: car.fromStreet,
        toStreet: car.toStreet,
        parkedAt: car.parkedAt,
        notifyOnRestriction: enabled
    )
    save(car)
}
```

### 4.B: SettingsView — ContentView Integration

`SettingsView` is a pure SwiftUI view. It reads/writes `AppConstants.notificationsMutedKey` directly via `UserDefaults.standard`. It does NOT need a reference to `NotificationScheduler` or `TileLoader` — those actions are handled by `ContentView` via callbacks.

**Approach: callback closures passed from ContentView.**

```swift
struct SettingsView: View {
    @Binding var notificationsMuted: Bool
    let onUnmute: () -> Void   // Called when toggle flips from OFF → ON
    let appVersion: String     // CFBundleShortVersionString
    let buildNumber: String    // CFBundleVersion
}
```

`onUnmute` in `ContentView`: reschedules notifications for the current pin if `parkedCar != nil && parkedCar.notifyOnRestriction == true`. This keeps `SettingsView` dependency-free (no `engine`, no `tileLoader`, no `ParkPinService` references in the settings view).

**`ActiveSheet.settings` case.**

Add to the `ActiveSheet` enum in `ContentView.swift`:

```swift
case settings
```

`id` returns `"settings"`. Add a case in the `.sheet(item:)` switch:

```swift
case .settings:
    SettingsView(
        notificationsMuted: $notificationsMuted,
        onUnmute: {
            if let car = parkPinService.parkedCar, car.notifyOnRestriction {
                NotificationScheduler.shared.schedule(
                    for: car,
                    loadedSegments: tileLoader.segments,
                    engine: engine
                )
            }
            ToastService.shared.show(message: "Reminders re-enabled")
        },
        appVersion: appVersion,
        buildNumber: buildNumber
    )
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
    .presentationBackground(.regularMaterial)
    .presentationCornerRadius(20)
```

`@State private var notificationsMuted: Bool` in `ContentView` — initialized from `UserDefaults.standard.bool(forKey: AppConstants.notificationsMutedKey)` in `.task { }`. This @State is the source of truth for the toggle binding; SettingsView writes through the binding, which triggers the `onChange` handler to write to UserDefaults and cancel/reschedule notifications as needed.

`appVersion` and `buildNumber` are read from `Bundle.main.infoDictionary` as string constants at the `ContentView` level and passed into `SettingsView`. Use `let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"` and the same pattern for `CFBundleVersion`.

**Why @State in ContentView, not in SettingsView.**  `ContentView` needs to know the mute state for overlay recompute commentary and for future features (e.g., showing a muted indicator in the toolbar). Keeping it in `ContentView` avoids prop-drilling later.

**Gear button placement.** Add to `ContentView.body`'s `ZStack`:

```swift
// Top-left: gear/settings button
VStack {
    Button { activeSheet = .settings } label: {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.secondary)
    }
    .accessibilityLabel("Open settings")
    Spacer()
}
.padding(.top, 60)
.padding(.leading, 12)
```

This mirrors the `.topTrailing` recenter stack exactly but is aligned `.topLeading`.

### 4.C: ASPBanner Integration into ContentView

The banner plugs into the existing `ZStack` in `ContentView.body` via `.safeAreaInset(edge: .top)`. This is applied to the `MapViewRepresentable`, not the `ZStack`, so the map insets itself rather than the overlay buttons.

**State.** Add to `ContentView`:

```swift
@State private var aspService = ASPSuspensionService()
@State private var bannerState: SuspensionBannerState = .aspInEffect
```

Compute `bannerState` on `.onAppear` and on `scenePhase == .active`:

```swift
.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active {
        bannerState = aspService.suspensionState(at: .nowET)
    }
}
```

`ASPBanner` is a simple view:

```swift
struct ASPBanner: View {
    let state: SuspensionBannerState

    var body: some View {
        HStack {
            Spacer()
            Text(bannerText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foregroundColor)
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
            Spacer()
        }
        .background(backgroundColor)
        .accessibilityLabel(accessibilityText)
    }

    private var bannerText: String {
        switch state {
        case .todaySuspended(let reason):    return "ASP Suspended — \(reason)"
        case .tomorrowSuspended(let reason): return "ASP Suspended Tomorrow — \(reason)"
        case .aspInEffect:                   return "ASP in Effect Today"
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .todaySuspended:    return .red
        case .tomorrowSuspended: return Color(red: 0.92, green: 0.76, blue: 0.0)
        case .aspInEffect:       return .green
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .tomorrowSuspended: return .black
        default:                 return .white
        }
    }

    private var accessibilityText: String {
        switch state {
        case .todaySuspended(let reason):
            return "ASP suspended today. Reason: \(reason). No need to move your car."
        case .tomorrowSuspended(let reason):
            return "ASP suspended tomorrow. Reason: \(reason)."
        case .aspInEffect:
            return "ASP in effect today. Move your car on schedule."
        }
    }
}
```

Applied in `ContentView.body`:

```swift
MapViewRepresentable(...)
    .ignoresSafeArea()
    .safeAreaInset(edge: .top) {
        ASPBanner(state: bannerState)
    }
```

**Note on recenter button offset.** After integrating the banner, run the simulator and verify the top-right gear + recenter buttons are not visually behind the banner. The `.safeAreaInset` pushes the map content but the `ZStack` overlay buttons are positioned relative to the `ZStack`, not the inset map. If the gear button or recenter stack appears under the banner, increase `.padding(.top, 60)` to `.padding(.top, 60 + 40)` (40 ≈ banner height). The exact value should be confirmed on device.

### 4.D: NotificationScheduler Per-Pin Check

Add a single guard inside `schedule(for:...)` after the global mute check (current line 100 of `NotificationScheduler.swift`):

```swift
// W7: Per-pin opt-in check.
guard car.notifyOnRestriction else { return }
```

Also add the same guard in `scheduleForTest(for:...)` at the same position for test coverage.

No other changes to `NotificationScheduler`.

### 4.E: Files touched summary

| File | Change | Owner |
|---|---|---|
| `Views/ASPBanner.swift` | NEW. `ASPBanner` view. | @ios-engineer |
| `Views/SettingsView.swift` | NEW. `SettingsView` with Form. No `termsURL` — omitted per resolved OQ-W7-1. | @ios-engineer |
| `Services/ToastService.swift` | NEW. `@MainActor @Observable` singleton. `show(message:duration:)` + auto-dismiss via `Task`. See §3.E. | @ios-engineer |
| `Views/ToastHostView.swift` | NEW. Reads `ToastService.shared`; renders Capsule-style toast with slide-down + fade transition. See §3.E. | @ios-engineer |
| `ContentView.swift` | `ActiveSheet.settings` case; gear button; `.safeAreaInset` for banner; `@State bannerState`; `@State notificationsMuted`; `onUnmute` callback (fires `ToastService.shared.show`); `ToastHostView` in root `ZStack`. | @ios-engineer |
| `Views/ParkConfirmView.swift` | Add reminder toggle. Introduce `PinConfirmResult`. Update `onConfirm` signature. | @ios-engineer |
| `Models/ParkedCar.swift` | Add `notifyOnRestriction: Bool`. Custom `CodingKeys` + `init(from:)` with default. | @ios-engineer |
| `Services/ParkPinService.swift` | Add `updateNotifyOnRestriction(_:)` method. | @ios-engineer |
| `Services/NotificationScheduler.swift` | Add per-pin `notifyOnRestriction` guard in `schedule` and `scheduleForTest`. | @ios-engineer |
| `Views/ParkedCarDetailView.swift` | Add reminder toggle row. Call `parkPinService.updateNotifyOnRestriction` + reschedule/cancel on flip. | @ios-engineer |
| `Views/BlockDetailView.swift` (`RuleRow`) | Tap-to-expand. `@State isExpanded`. Animated `lineLimit`. | @ios-engineer |
| `Services/Constants.swift` | No `termsURL` constant (resolved OQ-W7-1 — omit). Add any new UserDefaults key constants required by Settings. | @ios-engineer |

---

## 5. Work Streams

W7 is a single-engineer stream. All five sub-features touch disjoint files for the most part, with one seam: `ContentView.swift` touches the banner (4.C), settings (4.B), and the Toast host. Recommended implementation order within the PR:

1. **`ParkedCar` model change** (4.A) — data contract first. Everything else depends on this field existing.
2. **`NotificationScheduler` per-pin guard** (4.D) — one line, testable immediately.
3. **`ParkConfirmView` toggle + `PinConfirmResult`** (3.C) — isolated to one sheet view.
4. **`ParkedCarDetailView` toggle** — isolated to one sheet view.
5. **`RuleRow` tap-to-expand** (3.D) — isolated to `BlockDetailView.swift`.
6. **`ToastService` + `ToastHostView`** (3.E) — two new files; wire `ToastHostView` into `ContentView`'s `ZStack` before wiring the mute callback in step 8.
7. **`ASPBanner` view + `ContentView` integration** (3.A / 4.C) — new file + wiring.
8. **`SettingsView` + gear button + `ActiveSheet.settings` + mute-off toast trigger** (3.B / 4.B) — new file + wiring; calls `ToastService.shared.show(message: "Reminders re-enabled")` in the `onUnmute` closure.

Steps 3–5 are independent and can be developed in any order once step 1 is done. Step 6 (Toast primitive) is self-contained and can be done any time before step 8. Steps 7–8 both touch `ContentView.swift` and should be implemented sequentially. Since a single engineer owns this, run the full sequence top-to-bottom.

**No parallelism is needed in W7** — it is small enough to be one person's work. Total estimated effort: 1.5–2 engineer sessions.

---

## 6. Acceptance Criteria

Run on a real device (or Simulator for the items marked S) before marking W7 ready for QA.

### Banner (A)

- [ ] **AC-W7.1** On a date in `asp-2026.json` (e.g., simulate by temporarily adding today's date in the JSON during testing): app shows a **red** banner reading "ASP Suspended — [reason]" at the top of the map, below the status bar. The map content is pushed down, not overlapped. (S: acceptable to verify in Simulator with a test date.)
- [ ] **AC-W7.2** On the day before a suspended date (simulate as above): app shows an **amber-yellow** banner reading "ASP Suspended Tomorrow — [reason]" with **black** text.
- [ ] **AC-W7.3** On a normal non-suspended date: app shows a **green** banner reading "ASP in Effect Today" with **white** text.
- [ ] **AC-W7.4** Banner is never dismissible. Swiping on it, tapping it, or any interaction does not hide it.
- [ ] **AC-W7.5** Banner text is read by VoiceOver as a complete sentence (not just the visible abbreviation). The accessibilityLabel includes the reason for suspended states.
- [ ] **AC-W7.6** After the app goes to background and returns to foreground on a new calendar day (ET), the banner state updates to reflect the new date. (S: advance simulator clock past midnight ET, background and foreground the app.)
- [ ] **AC-W7.7** The gear button and find-me/find-my-car buttons are fully visible and tappable above the banner. No layout overlap.

### Settings (B)

- [ ] **AC-W7.8** A gear icon appears in the top-left of the map. Tapping it opens a sheet with a "Notifications" section containing a "Park-reminder notifications" toggle.
- [ ] **AC-W7.9** The toggle defaults to ON when `AppConstants.notificationsMutedKey` is absent or false.
- [ ] **AC-W7.10** Flipping the toggle OFF: persists `notificationsMutedKey = true` to `UserDefaults`. Kill and relaunch the app — toggle remains OFF.
- [ ] **AC-W7.11** When the toggle is flipped OFF while a pin exists with a pending notification: the pending notification is canceled (verify via iOS Notification Center — it should not appear in scheduled notifications list).
- [ ] **AC-W7.12** Flipping the toggle from OFF → ON while a pin exists (with `notifyOnRestriction == true`): a new notification is scheduled for the current pin. (S: check with `UNUserNotificationCenter.current().getPendingNotificationRequests` in Xcode.)
- [ ] **AC-W7.13** Settings sheet shows the correct app version string AND build number (e.g., "1.0 (42)") in the About section. No Terms or Privacy link appears — the footer contains only the version row.
- [ ] **AC-W7.14** Existing W6 global mute behavior in `NotificationScheduler.schedule` (line 100) is functionally unchanged — `notificationsMutedKey = true` still prevents scheduling. (Regression check.)

### Toast — Mute-Off Confirmation (E)

- [ ] **AC-W7.30** Flipping the global mute toggle from OFF → ON shows a toast reading exactly `"Reminders re-enabled"` near the top of the screen, above the ASP banner.
- [ ] **AC-W7.31** The toast auto-dismisses after approximately 3 seconds with a fade-out + slide-up animation. The user does not need to tap it.
- [ ] **AC-W7.32** If a second toggle flip (OFF → ON) occurs while the toast is still visible, the toast resets its 3-second timer (i.e., the previous auto-dismiss is canceled and the toast stays up for a full 3 more seconds). The message text does not duplicate.
- [ ] **AC-W7.33** The toast does not appear when the user flips the toggle from ON → OFF (muting). It is a confirmation of re-enabling only.
- [ ] **AC-W7.34** VoiceOver reads `"Reminders re-enabled"` as an announcement when the toast appears, even when VoiceOver focus is on a different element.
- [ ] **AC-W7.35** The toast is rendered above the ASP banner (it does not disappear behind it). Verify by triggering the toast while the red or amber-yellow banner is showing.
- [ ] **AC-W7.36** (S) `ToastService.shared.show(message: "Test message")` called programmatically in a debug build produces the toast in the expected position and dismisses after 3 seconds. This confirms the primitive is decoupled from the mute toggle and usable by future callers.

### Per-Pin Toggle (C)

- [ ] **AC-W7.15** `ParkConfirmView` shows a "Remind me before parking changes" toggle row, defaulting to ON, above the action row.
- [ ] **AC-W7.16** Confirming a pin with the toggle **ON**: a `ParkedCar` is saved with `notifyOnRestriction = true`. A notification is scheduled for ASP-restricted blocks (existing W6 behavior preserved).
- [ ] **AC-W7.17** Confirming a pin with the toggle **OFF**: `ParkedCar` saved with `notifyOnRestriction = false`. No notification is scheduled — verify with `getPendingNotificationRequests`.
- [ ] **AC-W7.18** `ParkedCarDetailView` shows the same "Remind me before parking changes" toggle, reflecting the current `parkedCar.notifyOnRestriction` value.
- [ ] **AC-W7.19** Flipping the toggle in `ParkedCarDetailView` from OFF → ON: persists `notifyOnRestriction = true` via `ParkPinService.updateNotifyOnRestriction`, and schedules a notification (if global mute is OFF and the block has a restriction).
- [ ] **AC-W7.20** Flipping the toggle in `ParkedCarDetailView` from ON → OFF: persists `notifyOnRestriction = false`, cancels the existing notification.
- [ ] **AC-W7.21** Kill and relaunch the app. The `ParkedCarDetailView` toggle reflects the persisted `notifyOnRestriction` value (not always true on relaunch).
- [ ] **AC-W7.22** A pre-W7 pin in UserDefaults (missing `notifyOnRestriction` key) is loaded without a crash and treated as `notifyOnRestriction = true`.

### Sign-Text Truncation Fix (D)

- [ ] **AC-W7.23** A rule row with description `"NO PARKING 8AM-6PM EXCEPT SUNDAY METERED PARKING 30 MIN MAX"` displays as one truncated line by default.
- [ ] **AC-W7.24** Tapping the row expands it to show the full description, with the category badge still visible (either trailing or below the text — layout from §3.D).
- [ ] **AC-W7.25** Tapping the expanded row collapses it back to one line. The animation is smooth (no jump or flash).
- [ ] **AC-W7.26** The expand/collapse behavior works identically in both `BlockDetailView` and `ParkedCarDetailView` (which reuses `RuleRow`).
- [ ] **AC-W7.27** VoiceOver reads the appropriate hint ("Tap to expand full sign text." / "Tap to collapse.") for collapsed and expanded states.

### Regression

- [ ] **AC-W7.28** W6 deep-link flow (notification tap → `ParkedCarDetailView`) is unbroken. The `ActiveSheet` enum still includes all pre-W7 cases.
- [ ] **AC-W7.29** All 60 pre-W7 tests pass. `@ios-engineer` adds new tests for AC-W7.16, AC-W7.17, AC-W7.19, AC-W7.20, and AC-W7.22 (the `notifyOnRestriction` scheduling logic) plus the three `ToastService` unit tests in §7. Target: at least 8 new tests, raising the suite to 68+.

---

## 7. Test Plan

**New unit tests to add in `WeParkTests/`:**

| Test | What it covers |
|---|---|
| `testNotificationScheduler_perPinOptOut_skipsScheduling` | `ParkedCar.notifyOnRestriction = false` → `schedule()` returns without adding a request (mock center receives zero `add` calls). |
| `testNotificationScheduler_perPinOptIn_schedules` | `ParkedCar.notifyOnRestriction = true`, global mute OFF → `schedule()` calls `add` exactly once. |
| `testNotificationScheduler_globalMute_overridesPerPinOn` | `notificationsMuted = true`, `notifyOnRestriction = true` → zero `add` calls. Global mute wins. |
| `testParkedCar_decodeMissingNotifyKey_defaultsTrue` | Decode a JSON blob without `notifyOnRestriction` key → decoded car has `notifyOnRestriction == true`. |
| `testASPSuspensionService_todaySuspended_returnsBannerState` | `suspensionState(at: knownSuspendedDate)` returns `.todaySuspended(reason:)` with the correct reason string. (This test may already exist from W3; if so, skip and add a note.) |
| `testToastService_show_setsCurrentMessage` | Call `ToastService.shared.show(message: "Hello")` — `currentMessage` is immediately `"Hello"`. |
| `testToastService_show_replacesExistingMessage` | Call `show(message: "A")`, then immediately `show(message: "B")` — `currentMessage` is `"B"` and only one dismiss task is active. |
| `testToastService_autoDismiss_clearsMessage` | Call `show(message: "X", duration: 0.1)` — after 0.2 seconds (using `Task.sleep` in the test), `currentMessage` is `nil`. |

**Manual smoke checklist (on device or Simulator):**

1. Fresh install. Open app. Confirm green "ASP in Effect Today" banner shows.
2. Temporarily add today's date to `asp-2026.json`. Rebuild. Confirm red banner with correct reason. Verify map is not obscured by banner.
3. Tap gear icon. Settings sheet opens. Toggle "Park-reminder notifications" to OFF. Dismiss. Drop a pin on an ASP block. Open iOS Settings → Notifications (or use `getPendingNotificationRequests` in Xcode) — confirm no WePark notifications are pending.
4. Reopen Settings. Toggle notifications back ON. Drop a pin on an ASP block with the per-pin toggle ON. Confirm a notification appears in `getPendingNotificationRequests`.
5. Drop a pin with the per-pin toggle OFF. Confirm zero new notifications scheduled.
6. Open `ParkedCarDetailView`. Flip per-pin toggle OFF→ON. Confirm notification scheduled. Flip ON→OFF. Confirm notification canceled.
7. Tap a block with a long rule description (`"NO PARKING 8AM-6PM EXCEPT SUNDAY METERED PARKING 30 MIN MAX"` is on real segments — find one). Confirm truncation. Tap row — confirm expansion. Tap again — confirm collapse.
8. Kill the app. Relaunch. Verify the `ParkedCarDetailView` toggle reflects persisted `notifyOnRestriction` value.
9. Open Settings. Toggle notifications OFF, then back ON. Confirm the toast `"Reminders re-enabled"` appears near the top of the screen, above the ASP banner, and auto-dismisses in ~3 seconds. Confirm the toast does NOT appear when toggling OFF.
10. Trigger the toast while the red "ASP Suspended" banner is showing (temporarily add today's date to `asp-2026.json`). Confirm the toast renders above the banner with no overlap or z-order issue.

---

## 8. Out-of-Scope Follow-Ups

These were noticed during spec authoring and explicitly deferred. Each is a candidate for W8 or post-MVP.

- **Terms of Service / Privacy Policy in Settings footer.** Kevin confirmed he wants legal links eventually but does not yet have hosted URLs or finalized copy. Decision: omit from v1 (see Resolved Decisions above). Once copy is drafted and hosted, add a single `Link("Terms & Privacy", destination: termsURL)` row to `SettingsView`'s About section and a corresponding `AppConstants.termsURL: URL` constant. This is a non-engineering task first (writing the copy). Carry this item into `HANDOFF.md` when W7 ships.
- **W6.1 deep-link flake.** The `ParkedCarDetailView` sheet sometimes fails to present after notification tap in Simulator. Isolated in `HANDOFF.md` carry-overs. Not touched in W7. Recommend dedicating one session to this before W8 TestFlight submission since it is a user-visible rough edge.
- **"Tomorrow suspended" proactive notification.** The banner tells the user about tomorrow. A notification fired the evening before a suspension day ("Tomorrow's ASP is suspended — no need to move!") would be a strong user-delight feature. Post-MVP — requires new notification content and a new scheduling path.
- **Settings: notification lead time adjustment.** Power users want 30 min instead of 1 hour. `AppConstants.notificationLeadTimeSeconds` is a single constant; a stepper in Settings is trivial to add. Deferred — the 1h default covers the MVP use case.
- **Settings: "Expand all sign text" preference.** Some users may always want to see full sign text without tapping. A toggle in Settings that sets a `UserDefaults` flag checked by `RuleRow` would be simple. Deferred — the tap-to-expand default is a reasonable first pass.
- **Accessibility: map-level VoiceOver for blocks.** `HANDOFF.md` carry-overs note that `MKAnnotation` per segment was dropped in W4 for performance. Post-MVP: lightweight annotations at reduced zoom density.
- **Banner: ASP suspended but tomorrow not suspended.** The banner correctly shows the today-suspended state and transitions to `aspInEffect` the next day. If Kevin wants a "returning to normal tomorrow" state (a fourth banner state for the day after a suspension), that is a UX addition not in scope.

---

## 9. PR Strategy

**Recommendation: one PR, not two.**

Rationale: the four bundled items are tightly coupled through `ParkedCar` (the `notifyOnRestriction` field affects the model, both confirm views, `NotificationScheduler`, `ParkPinService`, and the settings screen). Splitting would require a stub field in the model PR and a second round of review on the same model file. The diff size is manageable — the five items together are approximately 430–570 lines of new/modified Swift across 12 files, with `ASPBanner.swift`, `SettingsView.swift`, `ToastService.swift`, and `ToastHostView.swift` being the four largest new additions (~80–120 LOC added for the Toast primitive alone, +2 files over the original 10). One PR keeps the model change atomic with its consumers.

**File and LOC estimate:** 12 files total (10 previously estimated + `ToastService.swift` + `ToastHostView.swift`). LOC: ~430–570 new/modified Swift lines (was ~350–450 before Toast addition). Test suite target: 68+ tests (was 65+; 3 additional Toast unit tests).

If Kevin prefers a split for review ergonomics, the natural seam is:
- **PR W7a:** `ParkedCar.notifyOnRestriction` + `NotificationScheduler` per-pin guard + `ParkConfirmView` toggle + `ParkedCarDetailView` toggle + `ParkPinService.updateNotifyOnRestriction` (C items only, plus model).
- **PR W7b:** `ASPBanner` + `SettingsView` + gear button + `ActiveSheet.settings` + `RuleRow` tap-to-expand (A, B, D items).

W7a would need to ship and merge before W7b, since W7b touches `ContentView.swift` which W7a also touches (`confirmPinDrop` changes). If Kevin wants two PRs, signal before the engineer starts so the branch strategy is correct.
