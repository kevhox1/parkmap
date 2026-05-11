# WePark iOS MVP — Color Palette & Block Visualization Spec

**Status:** Revised 2026-05-10 (severity-spectrum + dynamic-state reframe, open questions closed).
**Owner:** @designer.
**Feeds into:** `docs/ios-mvp-spec.md` §3.7 and W1.5.
**Gating:** iOS Engineer does not start pixel work on map polylines, block detail sheet, or ASP banner until this doc is marked complete.

---

## 1. Design premise

**Color encodes CURRENT STATE, not static category.** The same ASP_MON_THU block changes color throughout the week as its actual parking state changes — red when ASP is active Thursday 7-9:30am, orange Wednesday evening (restriction coming in <24h), green for the two days in between. This is intentional. A driver mid-search wants the visual answer to *"where do I park RIGHT NOW"*, not a list of *"what kind of restrictions exist on each block."*

WePark's parking states sit on a natural severity gradient — from a block where you'll get ticketed and towed if you park wrong, down to a block where you can leave the car for days. Color encodes that gradient *as it applies right now*. A driver who glances at the map for two seconds while stopped at a light should read current-state severity from color without counting on being able to tap into details.

The palette is a traffic-light-plus-amber spectrum: red (worst) → orange → amber-yellow → green (best). All four are SwiftUI system semantic colors; all four carry matching Apple HIG semantic meanings (red = destructive/critical, orange = warning, yellow = caution, green = success/go). All auto-adapt for Dark Mode without any manual dark-hex management.

Source: Apple Human Interface Guidelines — Color: https://developer.apple.com/design/human-interface-guidelines/color

---

## 2. Palette

### 2.1 Color-to-current-state mapping

The PWA has 12 sign categories. For the map, color is determined not by the category but by the **current state** at evaluation time. The same block changes color as its current state changes throughout the day or week. Sub-category detail (Mon/Thu vs Tue/Fri ASP, truck loading vs no standing) is text in the block detail sheet — not a separate color.

| Severity rank | Current state right now | Triggered by | SwiftUI color | Rationale |
|---|---|---|---|---|
| 1 (worst) | **Can't park** | NO_PARKING anytime; ASP block during its active window (e.g., Thu 7–9:30am for an ASP_MON_THU block); NO_STANDING; TRUCK_LOADING active now; SPECIAL active now | `Color.red` | You cannot park here at this moment. Ticket + potential tow. |
| 2 | **Free now, restriction coming soon** | ASP block whose next active window starts within ~24 hours (engine decides exact threshold) | `Color.orange` | Warning state. Fine for a quick errand, not safe for overnight parking. Driver gets the "be careful, set a timer" signal at a glance. |
| 3 | **Metered (pay to park) right now** | METERED block during its active billing hours | `Color(red: 0.92, green: 0.76, blue: 0.0)` — amber-shifted yellow (see §2.3) | Pay-or-ticket. No tow risk. Manageable. |
| 4 (best) | **Free now, no restriction imminent** | FREE block; OR ASP block whose next active window is >24h away; OR METERED block during its free hours | `Color.green` | Park comfortably. Safe for overnight if no near-term restriction. |
| neutral | **Unknown** | Segment with no rules or unrecognized category | `Color.gray.opacity(0.35)` | No data. User should look at the signs. Sits outside the severity spectrum. |

**Same block, different color through the week** — concrete example, ASP_MON_THU block (street cleaning Mon + Thu, 7–9:30am):

| Wall-clock time (ET) | Current state | Color |
|---|---|---|
| Mon 7:00–9:30am | ASP active | 🔴 Red |
| Mon 9:30am – Wed evening (next ASP > 24h away) | Free now, far from next | 🟢 Green |
| Wed evening – Thu 6:59am (within 24h of next ASP) | Free now, restriction coming | 🟠 Orange |
| Thu 7:00–9:30am | ASP active | 🔴 Red |
| Thu 9:30am – Sun (next ASP is Mon, > 24h away) | Free now, far from next | 🟢 Green |

The exact "soon" threshold (24h, 12h, "today") is the engine's call — `@ios-engineer` may tune based on user testing. 24h is the spec's recommendation.

### 2.2 SwiftUI implementation

Color enum lives at `ios/WePark/WePark/Services/ParkingColors.swift`:

```swift
import SwiftUI

enum ParkingColors {
    /// Cannot park right now. NO_PARKING; ASP active in current window; NO_STANDING; etc.
    static let restricted = Color.red

    /// Free right now, but a restriction is starting within ~24 hours.
    static let restrictionComingSoon = Color.orange

    /// Metered (pay to park) right now. See §2.3 on amber-shift.
    static let meteredActive = Color(red: 0.92, green: 0.76, blue: 0.0)

    /// Free right now with no restriction imminent.
    static let freeComfortably = Color.green

    /// Unknown — no data available.
    static let unknown = Color.gray.opacity(0.35)
}
```

The current-state-to-color mapping lives in `ParkingRulesEngine` (W3), not in the color enum — the engine computes the live state and returns the right color. Pseudocode:

```swift
extension ParkingRulesEngine {
    /// Returns the SwiftUI color representing the segment's CURRENT parking state.
    /// Recomputed on app foreground + map camera change.
    func currentStateColor(for segment: Segment, at now: Date) -> Color {
        let state = currentState(for: segment, at: now)   // existing helper
        switch state {
        case .restrictedNow:           return ParkingColors.restricted
        case .freeButRestrictionSoon:  return ParkingColors.restrictionComingSoon
        case .meteredActive:           return ParkingColors.meteredActive
        case .freeComfortably:         return ParkingColors.freeComfortably
        case .unknown:                 return ParkingColors.unknown
        }
    }
}
```

Map polyline usage (iOS 17 MapKit `MapPolyline`, from `ContentView`):

```swift
MapPolyline(coordinates: segment.coordinates)
    .stroke(engine.currentStateColor(for: segment, at: .now),
            style: StrokeStyle(
                lineWidth: engine.isMeteredActive(for: segment, at: .now) ? 4 : 3,
                lineCap: .round,
                lineJoin: .round
            ))
```

**Recompute cadence**: when the app enters foreground; when the map camera region settles after pan/zoom; AND on a 60-second timer while the app is active. The timer covers the "user leaves app open and idle" case — without it, colors would drift stale as the clock passes ASP-window boundaries. Power cost is negligible for a foreground app. Recomputation is local-data, cheap.

**Interim state**: W2 (PR #13) renders polylines with the old static `dominantCategory.swiftUIColor`. W3's PR refactors `ContentView` to call `engine.currentStateColor` instead. Until W3 lands, the map will display ASP blocks as orange even when they're currently free — a known interim issue tolerated for ~one PR cycle.

The `lineWidth` bump for active-metered is addressed in §2.3 below.

### 2.3 Yellow on a map — implementation note

Pure `Color.yellow` (OKLCH approximately `L=0.97`) is nearly indistinguishable from the light tan/beige of Apple Maps' default base layer in daylight. Two mitigations, applied together:

**Mitigation A — slightly amber-shifted yellow.**
Use `Color(red: 0.92, green: 0.76, blue: 0.0)` instead of `Color.yellow`. This is still unambiguously yellow to any viewer and reads the same semantically, but its luminance is lower (approximately 0.50 relative luminance vs 0.93 for pure yellow) and its hue pushes toward amber, which lifts it off the warm-beige basemap.

Update `ParkingColors.metered` accordingly:

```swift
static let metered = Color(red: 0.92, green: 0.76, blue: 0.0)
```

**Mitigation B — heavier stroke weight for metered segments.**
Metered polylines use `lineWidth: 4` (vs 3 for all others). The wider stroke makes the yellow line visible even when the fill color is marginally lower contrast than the map background.

If QA on a real device finds yellow is still washing out at zoom 14 on the default Apple Maps basemap, escalate to adding a thin dark stroke underneath using a `MapPolyline` layer rendered before the colored one — `Color.black.opacity(0.25)` at `lineWidth: 6` creates a subtle outline effect. This is the nuclear option; try A+B first.

---

## 3. ASP banner

Three states, matching `renderASPStatusBanner` in `index.html`:2093:

| Banner state | Background | Foreground / text | Wording |
|---|---|---|---|
| Today suspended | `Color.red` (system) | `Color.white` | "ASP Suspended — [reason]" |
| Tomorrow suspended | `Color.yellow` / amber-yellow `Color(red: 0.92, green: 0.76, blue: 0.0)` | `Color.black` | "ASP Suspended Tomorrow — [reason]" |
| Otherwise (ASP in effect) | `Color.green` (system) | `Color.white` | "ASP in Effect Today" |

Banner state-3 wording rationale: "ASP in Effect Today" (not "ASP Active" or "ASP Suspended? No") is the most unambiguous phrasing — it tells the driver the default condition (street cleaning will happen today, cars need to move on schedule). Kevin confirmed this wording 2026-05-10.

Banner implementation note: use `.safeAreaInset(edge: .top)` to push the banner below the status bar. Do not use padding arithmetic — SafeAreaInset handles device variance automatically.

---

## 4. Block visualization

### 4.1 Default: line-on-line polylines

Colored polylines drawn on top of the MapKit basemap, one per block face (left/right sides of the street are separate segments). This is the direct port of the PWA behavior.

Line style:
- `lineWidth: 3` for all categories except metered (`lineWidth: 4` — see §2.3).
- `lineCap: .round`, `lineJoin: .round`.
- Rendered in the `Map { }` builder's content closure, one `MapPolyline` per loaded segment.

### 4.2 Alternative visualizations (escalation path)

Per `docs/ios-mvp-spec.md` §3.1, if line-on-line produces frame rates below 30fps or looks visually cluttered on a real iPhone 12, escalate. The three alternatives to evaluate, in order of my recommendation:

**Alternative A — Zoom-threshold gating (not a visual redesign, but the first mitigation to try).**
Hide all polylines below zoom 13. At zoom 12 and lower, the basemap streets are thin enough that colored overlays just create noise. Above 13, polylines are meaningful. This is purely a performance + clarity optimization and should be implemented before considering the visual alternatives below.

**Alternative B — Reduced-opacity color wash with heavier current-block highlight.**
At lower zoom levels (13–15), render polylines at `opacity(0.5)`. On tap, the selected block snaps to full opacity and gets `lineWidth: 6`. This keeps the overview readable while giving the tapped block visual priority. No shape change, just opacity management.

**Alternative C — Block-center colored dots.**
Replace polylines with a single `MapAnnotation` dot at the midpoint of each block face. Dot: filled circle, diameter 8pt, color = block severity color, white ring border 1pt. Pros: ~80% reduction in render complexity; simpler hit detection. Cons: loses the spatial reading of "which side of this street has free parking." Acceptable for MVP if polylines genuinely don't perform.

If Alternative C becomes necessary, escalate back to @designer before shipping — the dot layout needs a pass to handle corner intersections where left/right dots overlap. That's a design problem, not an engineering one.

**Do not proceed to Alternative B or C without a stress-test result from a real device.** Default is polylines.

---

## 5. Accessibility

### 5.1 Colorblindness — luminance hierarchy

The four parking colors have the following approximate relative luminance values (sRGB, per WCAG 2.1 formula):

| Color | Hex approx | Relative luminance | Notes |
|---|---|---|---|
| `Color.red` (system, light mode) | #FF3B30 | ~0.21 | Darkest of the four |
| `Color.orange` (system, light mode) | #FF9500 | ~0.48 | Mid-luminance |
| Amber-yellow `(0.92, 0.76, 0.0)` | #EB9E00 | ~0.48 | Close to orange |
| `Color.green` (system, light mode) | #34C759 | ~0.30 | Between red and orange |

The honest finding: the four colors do NOT produce a clean luminance gradient that maps to severity order. Orange and amber-yellow are nearly identical in luminance (~0.48 each), and green (~0.30) sits between red (~0.21) and orange in luminance — not at the "best" end of the scale. For a deuteranope (red-green colorblind, ~6% of men), red and green both shift toward brown tones, making them potentially confusable.

**This is acceptable for a map overlay because color is augmentation, not the sole interface.** The critical information path is: color gives a quick orientation → tap gives text. The block detail sheet surfaces the exact safety label ("Free until Thu 9:30am", "No parking", "Metered until 7pm") in text, which is fully accessible. Color is the glance layer; text is the truth layer.

**Required mitigations to document in the accessibility section of the App Store privacy description and in the in-app settings:**

1. Every `MapPolyline` and annotation that carries severity color must have a corresponding `.accessibilityLabel` on the tap target (the `MapAnnotation` button that opens the block detail sheet). Example: `.accessibilityLabel("Metered parking. Tap for details.")`. This is a HIG requirement.

2. The block detail sheet must surface the safety label as the first element, in sufficiently large text (minimum `.body` style, Dynamic Type enabled). The color band on the sheet edge is decoration; the text is the accessibility anchor.

3. Do not add a color-only legend without an accompanying text legend. If a legend is added in a later phase, it must read "Red — No parking", not just swatches.

### 5.2 Dark Mode

All five colors (`Color.red`, `Color.orange`, amber-yellow custom, `Color.green`, `Color.gray.opacity(0.35)`) adapt for Dark Mode automatically. The amber-yellow custom value (`Color(red: 0.92, green: 0.76, blue: 0.0)`) does not adapt — it is the same hex in both modes. In Dark Mode, Apple Maps uses a dark basemap; amber-yellow still has sufficient contrast against it (the darker background makes warm colors read better, not worse). No Dark Mode override needed for the amber-yellow value.

The ASP banner "tomorrow suspended" state uses the amber-yellow color as background with black text. In Dark Mode, confirm this remains legible by running the Accessibility Inspector contrast checker during W4. Target: 4.5:1 minimum contrast ratio.

### 5.3 Touch targets

All interactive elements on the map — polyline tap areas, "Park here" button, banner dismiss — must be a minimum 44pt × 44pt. MapKit polylines have thin hit areas by default; if tap detection is unreliable in testing, expand the hit box using `MapPolyline`'s `onTapGesture` with a transparent wider overlay polyline (`lineWidth: 20`, `opacity(0.001)`) sitting above the visible one.

---

## 6. Out of scope (future)

- **Dark Mode custom palette tuning.** The system semantic colors handle the basics. If Kevin ships the app and runs it on a dark device and something looks off, that's a follow-up polish pass — not MVP.
- **Drive Mode palette.** Drive Mode is explicitly deferred (§2.2 of `docs/ios-mvp-spec.md`). When it ports, the side-of-street highlight overlay will need its own stroke + opacity spec for a heading-up interface. Separate doc at that time.
- **Pro tier color theming.** `docs/business-model.md` describes a WePark Pro tier landing post-MVP. If Pro introduces a custom map theme, the palette extension should be handled then.
- **Color legend UI.** A map legend ("what do the colors mean?") is useful but not MVP-blocking; first-time users will discover via tap. Add in v1.1 onboarding pass.

---

## 7. Decision log

| Date | Decision | What changed |
|---|---|---|
| 2026-05-10 (original) | Produced initial palette spec. Open questions: (1) severity-spectrum vs arbitrary color assignment, (2) banner state-3 wording, (3) unknown opacity. | Created doc. Proposed red/blue/orange/green. |
| 2026-05-10 (this revision) | Severity-spectrum reframe (Kevin's direction). Open questions #2 and #3 closed. | Replaced blue (metered) with amber-yellow; replaced orange (ASP) to remain orange; reordered so red > orange > yellow > green encodes severity worst-to-best. Banner state-3 wording locked to "ASP in Effect Today". Unknown opacity locked to 0.35. Added §2.3 legibility mitigations for yellow. Updated accessibility section with honest colorblind analysis. |
