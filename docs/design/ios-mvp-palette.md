# WePark iOS MVP — Color Palette & Block Visualization Spec

**Status:** Revised 2026-05-10 (severity-spectrum + dynamic-state reframe, open questions closed).
**Owner:** @designer.
**Feeds into:** `docs/ios-mvp-spec.md` §3.7 and W1.5.
**Gating:** iOS Engineer does not start pixel work on map polylines, block detail sheet, or ASP banner until this doc is marked complete.

---

## 1. Design premise

**Color encodes CURRENT STATE, not static category.** The same ASP_MON_THU block changes color throughout the week as its actual parking state changes — red when ASP is active Thursday 7-9:30am, orange Thursday around 1am (within 6h of next ASP), green for the rest of the week. This is intentional. A driver mid-search wants the visual answer to *"where do I park RIGHT NOW"*, not a list of *"what kind of restrictions exist on each block."*

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
| 2 | **Free now, restriction coming soon** | ASP block whose next active window starts within ~6 hours. Warning state. Fine if you're staying less than 6 hours; set a timer if you are. Orange. | `Color.orange` | Warning state. Fine for a quick errand, not safe for overnight parking. Driver gets the "be careful, set a timer" signal at a glance. |
| 3 | **Metered (pay to park) right now** | METERED block during its active billing hours | `Color(red: 0.92, green: 0.76, blue: 0.0)` — amber-shifted yellow (see §2.3) | Pay-or-ticket. No tow risk. Manageable. |
| 4 (best) | **Free now, no restriction imminent** | FREE block; OR ASP block whose next active window is >6h away; OR METERED block during its free hours | `Color.green` | Park comfortably. Safe for overnight if no near-term restriction. |
| neutral | **Unknown** | Segment with no rules or unrecognized category | `Color.gray.opacity(0.35)` | No data. User should look at the signs. Sits outside the severity spectrum. |

**Same block, different color through the week** — concrete example, ASP_MON_THU block (street cleaning Mon + Thu, 7–9:30am):

| Wall-clock time (ET), ASP_MON_THU (Mon + Thu 7–9:30am) | Current state | Color |
|---|---|---|
| Mon 7:00–9:30am | ASP active | 🔴 Red |
| Mon 9:30am – Thu 1:00am (next ASP > 6h away) | Free now, far from next | 🟢 Green |
| Thu 1:00am – Thu 6:59am (within 6h of next ASP) | Free now, restriction coming | 🟠 Orange |
| Thu 7:00–9:30am | ASP active | 🔴 Red |
| Thu 9:30am – Mon 1:00am (next ASP > 6h away) | Free now, far from next | 🟢 Green |

The "soon" threshold is 6h (W4.5 — lowered from 24h). See `docs/ios-color-threshold-spec.md` for rationale.

### 2.2 SwiftUI implementation

Color enum lives at `ios/WePark/WePark/Services/ParkingColors.swift`:

```swift
import SwiftUI

enum ParkingColors {
    /// Cannot park right now. NO_PARKING; ASP active in current window; NO_STANDING; etc.
    static let restricted = Color.red

    /// Free right now, but a restriction is starting within ~6 hours.
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
- **Drive Mode palette.** Drive Mode chip badges are now specified (§8, TF2-18). Still out of scope: a side-of-street highlight overlay directly ON the map itself for a heading-up interface — that remains deferred, separate doc at that time.
- **Pro tier color theming.** `docs/business-model.md` describes a WePark Pro tier landing post-MVP. If Pro introduces a custom map theme, the palette extension should be handled then.
- **Color legend UI.** A map legend ("what do the colors mean?") is useful but not MVP-blocking; first-time users will discover via tap. Add in v1.1 onboarding pass.

---

## 7. Decision log

| Date | Decision | What changed |
|---|---|---|
| 2026-05-10 (original) | Produced initial palette spec. Open questions: (1) severity-spectrum vs arbitrary color assignment, (2) banner state-3 wording, (3) unknown opacity. | Created doc. Proposed red/blue/orange/green. |
| 2026-05-10 (this revision) | Severity-spectrum reframe (Kevin's direction). Open questions #2 and #3 closed. | Replaced blue (metered) with amber-yellow; replaced orange (ASP) to remain orange; reordered so red > orange > yellow > green encodes severity worst-to-best. Banner state-3 wording locked to "ASP in Effect Today". Unknown opacity locked to 0.35. Added §2.3 legibility mitigations for yellow. Updated accessibility section with honest colorblind analysis. |
| 2026-05-11 | `nearFutureWindow` lowered from 24h to 6h. Dual-persona analysis surfaced during W4 verification; 6h chosen to serve the short-stay visitor as the primary map-color persona. Overnight resident served by text label + W6 notification. See `docs/ios-color-threshold-spec.md`. |  |
| 2026-07-10 (TF2-18) | Drive Mode bottom-card chip badges specified — solid-fill severity background + dark text (§8), replacing the WCAG-failing `opacity(0.15)` tint pattern. Restores the orange "restriction coming soon" tier to Drive Mode via the same `ParkingColors.restrictionComingSoon`. See `docs/design/drive-mode-ui-review-2026-07-09.md` (P1-1/P1-2) for the full review this section implements. | Added §8. |

---

## 8. Drive Mode chip badges (TF2-18)

`ios/WePark/WePark/Views/DriveModeBottomCard.swift` renders two "Left"/"Right" severity
chips in the Drive Mode bottom card. Pre-TF2-18 these used the same `opacity(0.15)`
tinted-background-with-saturated-text pattern as an early map-legend sketch — that
pattern computes to roughly 1.4–2.6:1 contrast in Light Mode (fails WCAG AA's 3:1
large-text floor at every severity) while the same pattern computes to ~9.8:1 in Dark
Mode. TF2-18 (design review `docs/design/drive-mode-ui-review-2026-07-09.md`, finding
P1-1) replaced this with a solid-fill badge, matching the `ASPBanner` pattern that was
already correct:

| Severity | Background | Text | Computed contrast (Light) | Computed contrast (Dark) |
|---|---|---|---|---|
| `.free` | `ParkingColors.freeComfortably` (`Color.green`) | `Color.black` | 9.46:1 | 10.39:1 |
| `.comingSoon` (new, TF2-18 P1-2) | `ParkingColors.restrictionComingSoon` (`Color.orange`) | `Color.black` | 9.55:1 | 10.22:1 |
| `.metered` | `ParkingColors.meteredActive` (amber `0.92, 0.76, 0.0`) | `Color(red: 0.15, green: 0.10, blue: 0.0)` (same near-black `ASPBanner` already uses for `.aspInEffect`) | 9.93:1 | 9.93:1 (fixed hex, doesn't adapt — see §5.2) |
| `.restricted` | `ParkingColors.restricted` (`Color.red`) | `Color.black` | 5.92:1 | 6.16:1 |
| `.unknown` | `Color(.secondarySystemGroupedBackground)` (unchanged) | `Color.secondary` (unchanged) | n/a — system colors, not severity-tinted | n/a |

**Deviation from the design review's literal suggestion:** the review recommended white
text for the red/green chips ("both dark enough"). Computed contrast against the actual
solid-fill backgrounds shows this is wrong — white-on-`Color.green` is 2.22:1 (fails even
the 3:1 large-text floor) and white-on-`Color.red` is 3.55:1 (fails the 4.5:1 normal-text
floor the chip's `.subheadline`/`.medium` text needs, since it isn't reliably "large text"
per WCAG's bold/size thresholds). Dark text clears AA normal-text on every severity in
both appearances instead. The review's underlying INTENT (WCAG-passing solid-fill chips,
matching `ASPBanner`) is preserved — only the specific text-color choice for red/green
changed. Flagged explicitly in the TF2-17/TF2-18 PR description per the spec-fidelity
norm.

**`.comingSoon` (TF2-18 P1-2):** a new `SafetyLabel.Severity` / `SideOpportunity` case,
orthogonal to this doc's existing `CurrentState.freeButRestrictionSoon` (§2.1 row 2) but
computed at the Drive Mode SIDE-AGGREGATION layer (`DrivingContextService.aggregateSideDetail`)
rather than the per-segment map layer (`ParkingRulesEngine.currentState`) — it restores the
same orange warning tier to the one surface (Drive Mode) where it had been silently
collapsing into green `.free`. Same `ParkingColors.restrictionComingSoon` color, same 6h
`ParkingRulesEngine.nearFutureWindowHours` threshold (exposed `internal` specifically so
this call site can reuse the exact constant — no second hardcoded "6h" literal).

Chip text now also carries TF2-17's detailed "Free until X" string (e.g. "Free until
Wednesday 9:30 AM") instead of the generic "Free — check signs" whenever the engine has a
specific upcoming restriction to report — see `docs/tf2-17-chip-free-until-spec.md`.
