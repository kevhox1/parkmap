# WePark iOS MVP — Color Palette & Block Visualization Spec

**Status:** Revised 2026-05-10 (severity-spectrum reframe, open questions closed).
**Owner:** @designer.
**Feeds into:** `docs/ios-mvp-spec.md` §3.7 and W1.5.
**Gating:** iOS Engineer does not start pixel work on map polylines, block detail sheet, or ASP banner until this doc is marked complete.

---

## 1. Design premise

WePark's parking states sit on a natural severity gradient — from a block where you'll get ticketed and towed if you park wrong, down to a block where you can leave the car for days. Color should encode that gradient. A driver who glances at the map for two seconds while stopped at a light should read severity from color without counting on being able to tap into details.

The revised palette adopts a traffic-light-plus-amber spectrum: red (worst) → orange → yellow → green (best). All four colors are SwiftUI system semantic colors; all four carry matching Apple HIG semantic meanings (red = destructive/critical, orange = warning, yellow = caution, green = success/go). All four auto-adapt for Dark Mode without any manual dark-hex management.

Source: Apple Human Interface Guidelines — Color: https://developer.apple.com/design/human-interface-guidelines/color

---

## 2. Palette

### 2.1 Collapsed categories

The PWA has 12 sign categories. For the map, collapse them into 5 visual buckets. Sub-category detail (Mon/Thu vs Tue/Fri ASP, truck loading vs no standing) is text in the block detail sheet — not a separate color.

| Severity rank | Parking state | Categories collapsed | SwiftUI color | Rationale |
|---|---|---|---|---|
| 1 (worst) | Restricted | NO_PARKING, NO_STANDING, TRUCK_LOADING, SPECIAL | `Color.red` | You cannot park here. Ticket + potential tow. |
| 2 | ASP street cleaning | ASP_MON_THU, ASP_TUE_FRI, ASP_DAILY, ASP_MON_SAT, and any other ASP variant | `Color.orange` | Looks free now but has a hard deadline where the car gets ticketed and towed (~$185 + ticket). Tow is worse than a meter ticket. |
| 3 | Metered | METERED | `Color.yellow` (see §2.3 for implementation note) | Pay-or-ticket. No tow risk. Manageable. |
| 4 (best) | Free | FREE | `Color.green` | Park freely; no schedule, no risk. |
| neutral | Unknown | any segment with no rules or unrecognized category | `Color.gray.opacity(0.35)` | No data. User should look at the signs. Sits outside the severity spectrum. |

### 2.2 SwiftUI implementation

```swift
import SwiftUI

enum ParkingColors {
    /// Ticket + tow risk. NO_PARKING, NO_STANDING, TRUCK_LOADING, SPECIAL.
    static let restricted = Color.red

    /// ASP street cleaning — looks free now, tow risk at next window.
    static let asp = Color.orange

    /// Metered — pay-or-ticket, no tow. See note below on map legibility.
    static let metered = Color.yellow

    /// Free parking — no restriction, no schedule.
    static let free = Color.green

    /// Unknown — no data available.
    static let unknown = Color.gray.opacity(0.35)
}
```

Map polyline usage (iOS 17 MapKit `MapPolyline`):

```swift
MapPolyline(coordinates: segment.coordinates)
    .stroke(ParkingColors.color(for: segment.resolvedCategory),
            style: StrokeStyle(
                lineWidth: segment.resolvedCategory == .metered ? 4 : 3,
                lineCap: .round,
                lineJoin: .round
            ))
```

The `lineWidth` bump for metered is addressed in §2.3 below.

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
