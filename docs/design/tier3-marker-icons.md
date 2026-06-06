# Tier 3 marker icons — design note
**Date:** 2026-06-05
**Author:** @designer
**For:** @ios-engineer (sub-PR #2, W8.5f) — placeholder values in use until this note lands.
**Spec refs:** `docs/tier3-patrol-report-spec.md §9`, `docs/community-1.0-direction.md §6 + §6.2`

---

## 1. Established visual language (read before anything else)

The existing `PinMarkerAnnotation.markerStyle(for:)` family is:

| Pin type | SF Symbol | Circle color | Semantic read |
|---|---|---|---|
| `filming` | `video.fill` | `systemPurple` | Authoritative / open-data |
| `special_event` | `star.fill` | `systemOrange` | Authoritative / open-data |

Both are authoritative Tier 1 pins: bright, filled circles, high chroma. Tier 3 crowd pins are ephemeral and unverified by definition — their visual weight should sit one rung below Tier 1 in the hierarchy. Same circle format (so the family reads as a system), but color choices that signal "community-reported" rather than "official."

Apple's native POI dots on MapKit are small, monochrome, and tap-through. Our markers are filled circles with centered SF Symbols at 32pt. As long as we stay in that filled-circle language we are already distinct from Apple's POI layer. The only additional rule: do not use `systemBlue`, which MapKit uses natively for user-location pulsing and generic points of interest.

---

## 2. `enforcement_active` marker

### Recommended icon

**`person.badge.clock.fill`** — available SF Symbols 5 / iOS 17.

This reads as "a person on the clock" — a civic worker or officer actively on duty. It is:
- Unambiguously a person in an official role (the badge element), not a cartoon cop car or flashing light.
- Free of weapons, emergency-vehicle silhouettes, and anything that visually codes as "danger / evade."
- Distinct from `star.fill` (event) and `video.fill` (filming) — no overlap with the Tier 1 set.
- Consistent with the "civic compliance" framing in `community-1.0-direction.md §6`: "Enforcement active on this block" prompts *move your car or feed the meter*, not *flee*.

**Color: `systemTeal`** (`UIColor.systemTeal`)

Teal is the system color that reads as "informational / civic" without the alarm of red or the authoritative brightness of the Tier 1 orange and purple. It does not collide with the parking-status palette (green/yellow/red = free/metered/restricted). It passes contrast as a filled circle background behind a white SF Symbol at the 32pt render size.

> **Why not `shield.fill` (engineer's placeholder)?**  
> `shield.fill` is the App Store icon, the security/lock-screen metaphor, and the macOS Gatekeeper symbol. On a parking map it reads as "security threat" or "blocked area" before it reads as "civic worker." The badge element in `person.badge.clock.fill` does the same civic-authority signaling in a friendlier register. If `person.badge.clock.fill` is unavailable on a specific device's SF Symbols build, the fallback is `person.fill` — same teal circle, no badge. Do not fall back to `shield.fill`.

### Sub_tag differentiation

**Keep one icon for all sub_tags. Surface the sub_tag in the detail sheet only.**

Three reasons:

1. The map is already reading `video.fill` + `star.fill` as a Tier 1 layer. Adding three visually similar `enforcement_active` variants (parking agent, cleaning truck, tow truck) at Tier 3 creates a marker legend that a glancing driver cannot decode at speed.
2. The sub_tag is optional — a user can report "enforcement active" with no sub_tag at all. A single icon that means "enforcement present" is always correct; a sub_tag-specific icon would sometimes be wrong.
3. The civically-clean lead framing (cleaning truck first, per spec and product direction) is best handled in `ReportSheet` copy ordering and `PinDetailSheet` display, not by adding a `truck.box.fill` variant to the map layer. If you render a broom-truck icon on the map, the enforcement-agent and tow-truck pins look different — the user has to learn the legend. One `person.badge.clock.fill` circle means "something enforcement-adjacent is happening on this block; tap to see what."

**Detail sheet sub_tag display:** in `PinDetailSheet`, when `pin.pinType == .enforcementActive` and `meta.subTag != nil`, show the sub_tag as a secondary label below the main title, e.g. "Cleaning truck" in `.secondary` color. No sub_tag icon needed here either — the label is clear.

### Accessibility label

```
"Enforcement active"                          // no sub_tag
"Enforcement active — Cleaning truck"         // sub_tag present
"Enforcement active — Parking agent"
"Enforcement active — Tow truck"
```

Set in `configure(for pin:)` by reading `EnforcementActiveMeta.subTag`. The accessibility value should include the time-since badge string, e.g. `"5m ago"`.

---

## 3. `sweeper_passed` marker

### Recommended icon

**`truck.box.fill`** — available SF Symbols 5 / iOS 17.

This is a direct, unambiguous representation of the vehicle class. A street sweeper is mechanically a specialized truck; `truck.box.fill` is the closest SF Symbol to a service vehicle. It is recognizable at glance, carries no alarm connotation, and is civically positive (the sweeper already passed = the block is now clear for parking).

> **Why not `exclamationmark.triangle.fill` (engineer's placeholder)?**  
> Caution triangles communicate danger or error. A sweeper that already passed is good news for the parker — the block is clear and enforcement risk from sweeping is resolved. A warning triangle inverts the emotional valence entirely. Even "sweeper approaching" (the other direction) is more accurately rendered as "heads up, time-sensitive info" than as a hazard. The triangle placeholder must be replaced.

**Color: `systemCyan`** (`UIColor.systemCyan`)

Cyan is adjacent to teal in the system palette and reads as "informational / time-sensitive" without alarm. It is visually distinct from teal (enforcement) at glance — a driver looking at a block with both pin types can tell them apart. Cyan also has no overlap with the parking-status green/yellow/red palette.

### Direction (passed vs. approaching)

**Same icon, different opacity.**

- `sweeper_passed` (direction: "passed"): full opacity — the information is certain and positive (block is now clear).
- `sweeper_passed` (direction: "coming_soon"): 70% opacity — the sweeper is approaching but not yet confirmed passed; the pin is more tentative.

This is a subtle signal, not a labeled differentiation. The detail sheet shows the direction string as a secondary label ("Sweeper passed" / "Sweeper approaching"). Do not add a second icon variant (e.g., an arrow overlay) — it creates a legend-learning burden at map scale.

### Accessibility label

```
"Sweeper passed"       // direction == "passed"
"Sweeper approaching"  // direction == "coming_soon"
```

Accessibility value: time-since badge string, e.g. `"Just now"`.

---

## 4. In-drive Report button

### Confirmed: `flag.fill` is the right icon

The engineer's placeholder (`flag.fill`, orange, inline with the End pill) is **confirmed**. Reasoning:

- `flag.fill` universally reads as "flag something / report" — it is the same icon Waze, Apple Maps reporting, and App Store review flows use for user-generated reports.
- It is visually distinct from all other icons in the drive overlay (`speaker.wave.2.fill` / `speaker.slash.fill` for mute; `location.fill` for approach strip).
- Orange on `.regularMaterial` passes contrast at the 32pt symbol size used in the drive overlay.

### One refinement: label the button

The spec sketch renders `flag.fill` as an icon-only button. Add a `.caption2` text label "Report" below the flag icon. The drive overlay already has the End pill with a text label — icon-only buttons in the same HStack create inconsistency and fail the glanceability requirement (a driver who hasn't seen the button before needs to know what it does in 1 second without tapping).

Implementation:

```swift
// Replace the icon-only label with:
label: {
    VStack(spacing: 2) {
        Image(systemName: "flag.fill")
            .font(.system(size: 17, weight: .medium))
        Text("Report")
            .font(.caption2)
            .fontWeight(.medium)
    }
    .foregroundStyle(Color.orange)
    .frame(minWidth: 44, minHeight: 44)
    .padding(.horizontal, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
}
```

The `.regularMaterial` pill matches the existing End Drive pill's material. The `minWidth: 44, minHeight: 44` satisfies HIG touch target minimum.

### Color: keep orange

Orange is established in the codebase as the `special_event` Tier 1 color. Using it for the Report button creates a mild collision — but the button is in the drive overlay, not on the map, so the contexts don't overlap simultaneously. Orange is also the conventional "action / alert" color for non-destructive UI actions in iOS (see: `UIAlertAction` default style, `UIBarButtonItem` in some contexts). It reads as "this does something important, immediately." Do not use red (destructive connotation) or blue (primary navigation). Orange is correct.

### Touch target

Minimum 44x44pt. The `minWidth: 44, minHeight: 44` frame plus `.contentShape(Rectangle())` ensures the full pill area is tappable, not just the icon.

### Accessibility

The spec sketch already has the correct label and hint:

```swift
.accessibilityLabel("Report enforcement or sweeper")
.accessibilityHint("Drops a pin at your current location.")
```

Keep both. The hint should not mention "two taps" — implementation details in hints age poorly and are confusing if the flow changes.

---

## 5. Time-since decay badge

### Position: callout subtitle (confirm the spec default)

The spec defaults to the callout subtitle (`MKAnnotation.subtitle`). **Confirm this choice.** Do not overlay a `UILabel` directly on the `MKAnnotationView` image (the 32pt circle). Reasons:

- Overlaying a text badge on a 32pt image is cramped — any readable font size (minimum ~10pt) will consume most of the circle and obscure the symbol.
- The callout subtitle is already wired and working for Tier 1 (`displaySubtitle` shows "Until HH:mm"). Adding `timeSinceBadge` as the subtitle for Tier 3 pins follows exactly the same pattern — zero new rendering code.
- Decay opacity fade (sub-PR #3) is the right place to surface aging visually on the marker itself. The subtitle handles the human-readable age string.

### Format: keep it short

The `timeSinceBadge` function from the spec (`"Just now"`, `"5m ago"`, `"1h ago"`) is correct. One addition: include an expiry note when a pin is within 10 minutes of its 30-minute TTL, so the callout communicates urgency:

```
age < 20 min:  "5m ago"          (standard)
age 20–25 min: "22m ago · expiring soon"
age > 25 min:  "27m ago · almost expired"
```

This is a sub-PR #3 detail, not a blocker for sub-PR #2. File it as a follow-up for the decay display pass. Sub-PR #2 ships the basic `timeSinceBadge` as specced.

### Sub-PR #3 decay visual (out of scope now, but spec it here)

When sub-PR #3 implements opacity fade on the `MKAnnotationView`, use this progression:

- Age 0–15 min: full opacity (1.0) — pin is fresh, high confidence.
- Age 15–25 min: linear fade to 0.5 — pin is aging, less certain.
- Age 25–30 min: 0.5 → 0.3 — nearly expired, visually receding.

Apply via `annotationView.alpha = ...` in `mapView(_:viewFor:)` after dequeue, computed from `pin.createdAt`. The alpha value should be re-applied on every `updateUIView` refresh cycle that touches the annotation. This is purely visual — it does not affect tap target or callout display.

---

## 6. Marker family summary

| Pin type | SF Symbol | Circle color | Touch target | Family position |
|---|---|---|---|---|
| `filming` (existing) | `video.fill` | `systemPurple` | 44pt | Tier 1 / authoritative |
| `special_event` (existing) | `star.fill` | `systemOrange` | 44pt | Tier 1 / authoritative |
| `enforcement_active` (new) | `person.badge.clock.fill` | `systemTeal` | 44pt | Tier 3 / ephemeral crowd |
| `sweeper_passed` (new) | `truck.box.fill` | `systemCyan` | 44pt | Tier 3 / ephemeral crowd |

The two Tier 1 colors (purple, orange) are high-chroma and visually dominant. The two Tier 3 colors (teal, cyan) are cool and recessive — they read as background information rather than alerts, which is the correct hierarchy. A map with all four pin types visible will read as: filming and events are prominent, enforcement and sweeper are present but not screaming.

---

## 7. `markerStyle(for:)` patch (for @ios-engineer)

Replace the `default` fallback in `PinMarkerAnnotation.markerStyle(for:)` with explicit cases. The `default: mappin.fill / systemGray` fallback should remain but only for truly unknown types:

```swift
private static func markerStyle(for pinType: PinType) -> (symbolName: String, color: UIColor) {
    switch pinType {
    case .filming:
        return ("video.fill", UIColor.systemPurple)
    case .specialEvent:
        return ("star.fill", UIColor.systemOrange)
    case .enforcementActive:
        return ("person.badge.clock.fill", UIColor.systemTeal)
    case .sweeperPassed:
        return ("truck.box.fill", UIColor.systemCyan)
    default:
        return ("mappin.fill", UIColor.systemGray)
    }
}
```

This is the complete switch extension for sub-PR #2. No other files in `PinMarkerAnnotation.swift` need to change for the icon spec.

---

## 8. Open item for @ios-engineer

Verify `person.badge.clock.fill` renders cleanly at 32pt circle / ~17.5pt symbol size on an iOS 17 simulator before committing. The badge element is small and may not resolve at the 55% scale factor used for the circle symbol. If the badge is not legible at render size, fall back to `person.crop.circle.badge.checkmark` (also SF Symbols 5 / iOS 17), which has better visual weight at small sizes. Do not fall back to `shield.fill` under any circumstance.

---

*This note is the design authority for Tier 3 marker icons. Engineering does not need further design sign-off to proceed. Questions to @designer only if a symbol is unavailable on the iOS 17 target and neither this note nor the fallback above applies.*
