# WePark iOS MVP — Color Palette & Visualization Spec (W1.5)

**Owner:** @designer
**Status:** Draft for engineer review — 2026-05-10
**Feeds:** W2 (map render), W4 (block detail sheet), W7 (ASP banner)
**Spec anchor:** `docs/ios-mvp-spec.md` §3.7 (starting palette), §5 W1.5 (this deliverable)

---

## 1. Glanceability principles

These four principles govern every map-visual decision in WePark. Any future proposal that conflicts with one of them should explicitly justify the trade-off.

- **Color is the primary signal; text is the disambiguator.** A driver glancing at the phone for 1–2 seconds at a stoplight must read the block color before reading anything else. The sub-type — Mon/Thu vs Tue/Fri ASP, metered-paid vs metered-free — lives in the block detail sheet as text. Do not add a new map color to express a distinction that text can handle.

- **Pop against the base map, not blend into it.** MapKit's base map (Apple Maps native rendering) uses soft pastels and muted grays for streets and buildings. Parking overlays must be visually dominant at zoom 14–18. This means saturated, high-opacity colors — not semi-transparent tints that wash out against the light-gray street grid. The Apple Maps substrate is a feature, not a neutral canvas.

- **Never let color be the only signal.** WCAG 2.1 SC 1.4.1 requires that color not be the sole means of conveying information. Green/orange/red are a known failure vector for red-green colorblind users (~8% of males). Every color state must have a redundant text label in the block detail sheet. At minimum, the map line weight can also vary (see §3). Reference: [WCAG 1.4.1](https://www.w3.org/WAI/WCAG21/Understanding/use-of-color.html).

- **Saturated colors respect Dark Mode without custom hex.** SwiftUI semantic system colors (`Color.green`, `Color.orange`, `Color.red`, `Color.blue`, `Color.gray`) automatically shift their rendering for Dark Mode in ways that hand-tuned hex values cannot replicate without explicit light/dark asset variants. Start with system colors. Override with a custom hex only when a system color's semantic meaning is wrong for the context (see §2 notes on Unknown opacity).

---

## 2. Final color palette

### Collapsed category mapping

The PWA defines 12 categories in `CATEGORIES` at `index.html`:1558. Per spec §3.7, these collapse to 5 map colors. The full category-to-color mapping is:

| PWA category | Map color bucket |
|---|---|
| `FREE` | Free |
| `METERED` | Metered |
| `ASP_MON_THU` | ASP Cleaning |
| `ASP_TUE_FRI` | ASP Cleaning |
| `ASP_OVERNIGHT_MWF` | ASP Cleaning |
| `ASP_OVERNIGHT_TTHS` | ASP Cleaning |
| `ASP_DAILY` | ASP Cleaning |
| `NO_PARKING` | Restricted |
| `NO_STANDING` | Restricted |
| `TRUCK_LOADING` | Restricted |
| `SPECIAL` | Restricted |
| `UNKNOWN` | Unknown |

Sub-flavor distinctions (Mon/Thu vs Tue/Fri vs overnight) are communicated in the block detail sheet label, not on the map. This is the §3.7 "driver glanceability > taxonomic completeness" decision.

### Color table

| Name | SwiftUI value | Light Mode appearance | Dark Mode appearance | Accessibility note |
|---|---|---|---|---|
| **Free** | `Color.green` | Saturated green (~#34C759 on iOS) | Same hue, lightness-adjusted by system | Fails red-green colorblind (deuteranopia/protanopia) in isolation. Mitigated by text label in detail sheet + line weight contrast vs Restricted (see §3). |
| **Metered** | `Color.blue` | iOS system blue (~#007AFF) | Adapts to ~#0A84FF in Dark Mode | Blue is distinguishable under all common colorblindness types and separates cleanly from both green and orange. No custom hex needed — `Color.blue` resolves to iOS system blue. |
| **ASP Cleaning** | `Color.orange` | iOS system orange (~#FF9500) | Adapts to ~#FF9F0A in Dark Mode | Orange is the established "caution / time-sensitive" signal in the existing PWA (`ASP_TUE_FRI`: `#f97316`). Distinguishable from green and red under deuteranopia. Strong contrast against Apple Maps' light base. |
| **Restricted** | `Color.red` | iOS system red (~#FF3B30) | Adapts to ~#FF453A in Dark Mode | Fails red-green colorblind in isolation vs Free. Redundant signals: (a) text label in detail sheet, (b) heavier line weight vs Free/Metered/ASP (see §3). |
| **Unknown** | `Color.gray.opacity(0.35)` | Light gray, ~35% opaque | Same hue, system-adjusted | Low salience is intentional — unknown blocks should recede visually. The `0.35` opacity is a downward adjustment from the §3.7 starting value of `0.4`; the starting value was slightly too prominent. Verify on device in both modes. |

**Rationale for using system colors throughout.** SwiftUI system colors inherit the user's "Increase Contrast" accessibility setting automatically — when a user enables Increase Contrast in iOS Settings, `Color.green`, `Color.red`, etc. shift to higher-contrast variants without any additional code. Custom hex values do not. This is a meaningful accessibility win at zero implementation cost. Reference: [Apple HIG — Color](https://developer.apple.com/design/human-interface-guidelines/color).

**No sixth color.** There is no justification for a sixth map color in the MVP scope. "Free (currently)" vs "Free (ASP day but not now)" is a useful distinction in the block detail sheet; it does not warrant a separate hue on the map. The confusion cost of a six-color legend exceeds the information gain. This can be revisited in a post-MVP design iteration if real user testing surfaces confusion.

### SwiftUI implementation reference

```swift
extension Color {
    static let parkingFree       = Color.green
    static let parkingMetered    = Color.blue
    static let parkingASP        = Color.orange
    static let parkingRestricted = Color.red
    static let parkingUnknown    = Color.gray.opacity(0.35)
}
```

Define these in a `ParkingColors.swift` extension (or alongside `Category.swift`) so all views pull from one source. Do not inline `Color.green` etc. at call sites — the extension is the single source of truth.

---

## 3. Block visualization

### The decision: line-on-line, with an escalation plan

**Recommendation: Default line-on-line. Escalate to Alternative C (hybrid) only if the W2 stress test fails.**

#### Default: line-on-line (polylines over the street)

This is the natural first build and matches the PWA pattern (`index.html`:3674 — `seg.layer.setStyle({ color, weight: 5, opacity: 0.75 })`). It requires no new geometry or computation beyond what the tile JSONs already provide.

Implementation target for W2:

- **Line weight:** `lineWidth: 4` in MapKit's polyline renderer. The PWA uses Leaflet `weight: 5` CSS pixels; MapKit points on a 3x Retina display are visually equivalent at 4.
- **Opacity:** `1.0` for Free, ASP, Restricted. `0.35` for Unknown (matching §2).
- **Off-screen culling:** Port the visible-bounds gating from `index.html`:3456 (`loadVisibleTiles`). Do not render polylines outside `MKMapView.visibleMapRect`. This is the primary performance mitigation (spec §3.1, mitigation 1).
- **Zoom threshold:** Render nothing below the MapKit zoom equivalent of ~tile zoom 14. At lower zoom, individual block faces are sub-pixel and color bleed produces visual mud. Show only the base map below this threshold; optionally add a one-line "Zoom in to see parking data" status label if the user is zoomed out significantly. (Spec §3.1, mitigation 2.)

**W2 stress test (required before W4 starts).** Load all visible tiles at zoom 14 with Manhattan fully in view. Measure frame rate on an iPhone 12 (the AC-2 target). If sustained below 30fps under the full mitigation stack, escalate to Alternative C before proceeding to W4.

#### Alternative A: colored block-center dots

One `MapAnnotation` per block face at the midpoint of its polyline geometry. Rendering ~12,560 dots vs ~40,664 polyline segments is substantially cheaper for MapKit's compositing engine. Dots degrade gracefully at low zoom — they cluster into a readable color mass. Downside: you lose side-of-street alignment information. A user cannot tell which side of the block a dot represents. This is acceptable for a neighborhood overview but problematic for the "which side do I park on?" core use case.

#### Alternative B: shaded building footprints

Colors the building polygon on each block face rather than the street line. Visually rich and unambiguous about side of street. Requires polygon data we do not have — the tile JSONs contain polyline geometry only. Out of scope for MVP; revisit only if a building-footprint dataset becomes available.

#### Alternative C: hybrid (the escalation path)

- Zoom >= 16: full polylines (line-on-line). At this zoom, individual blocks dominate the screen; line weight and position are fully legible. This is the "I just parked, looking at my block" use case.
- Zoom 14–15: colored dots at block midpoints (Alternative A). Neighborhood-scale overview. Dots convey density and category without the rendering cost of 40k segments.
- Zoom < 14: nothing rendered. Base map only with a "Zoom in to see parking" hint.

The hybrid approach substantially reduces the rendering surface area at the zoom level where MapKit performance is most at risk (14–15), while preserving full polyline fidelity where it matters most (16+). This is consistent with how Apple Maps progressively discloses POI density — sparse at wide view, rich at street level.

**If the W2 stress test passes at 30fps on iPhone 12 with line-on-line + mitigations: ship line-on-line. Do not over-engineer.** Alternative C is the escalation path, not the starting point.

### Line weight and the colorblind redundancy signal

The §1 principle "never let color be the only signal" requires a non-color redundancy on the map itself (the detail sheet text is a redundancy, but only after a tap). On the map:

- **Restricted** lines: `lineWidth: 5` — one point heavier than the default. Signals "hard boundary, do not park here" independent of hue.
- **Free, Metered, ASP** lines: `lineWidth: 4` — default weight.
- **Unknown** lines: `lineWidth: 3`, opacity 0.35 — deliberately receded.

This produces three visual tiers (heavy / normal / light) that track the severity hierarchy independently of color. Under deuteranopia simulation, a user sees: heavy muted lines (Restricted), medium lines in two hues they may or may not distinguish (Free vs ASP — orange and green shift toward similar yellow-brown under deuteranopia), and thin light lines (Unknown). The weight difference between Restricted and the rest is sufficient for the user to identify "do not park here" blocks without relying on the red/green distinction.

---

## 4. Banner color spec

The three states mirror the PWA's `renderASPStatusBanner` at `index.html`:2093–2133. The PWA uses hardcoded hex values that do not adapt to Dark Mode. iOS uses SwiftUI system semantic colors throughout to get Dark Mode adaptation for free.

### State 1: Today suspended (highest urgency)

| Property | Value |
|---|---|
| **Background** | `Color(UIColor.systemRed).opacity(0.12)` — light mode ~#FEF2F2; dark mode auto-darkened by system |
| **Text color** | `Color(UIColor.systemRed)` — full system red saturation |
| **Border** | `Color(UIColor.systemRed).opacity(0.35)`, 1pt |
| **Icon** | `exclamationmark.octagon.fill` (SF Symbol — the octagon is Apple's visual convention for critical/stop-level alerts, consistent with how iOS renders emergency-level system notifications) |
| **Icon color** | `Color(UIColor.systemRed)` |
| **Primary text** | "ASP Suspended Today" — bold, `.headline` font style |
| **Secondary text** | Reason string from `asp-2026.json`, e.g. "New Year's Day" — regular weight, `.caption` font style |

PWA equivalents for regression verification: `background: #fef2f2`, `color: #991b1b`, `border: 1px solid #fecaca` at `index.html`:2107–2109.

### State 2: Tomorrow suspended (advisory)

| Property | Value |
|---|---|
| **Background** | `Color(UIColor.systemYellow).opacity(0.12)` — light mode ~#FFFBEB; dark mode system-adjusted |
| **Text color** | `Color(UIColor.systemOrange)` — orange, not yellow. Yellow as a text color on a white or pale background fails WCAG AA contrast (ratio ~1.4:1 against white). `systemOrange` on `systemYellow.opacity(0.12)` achieves the PWA's amber-brown intent with better contrast and no custom hex. |
| **Border** | `Color(UIColor.systemYellow).opacity(0.50)`, 1pt |
| **Icon** | `exclamationmark.triangle.fill` (SF Symbol — the triangle is Apple's advisory/warning tier, one level below the octagon) |
| **Icon color** | `Color(UIColor.systemOrange)` |
| **Primary text** | "ASP Suspended Tomorrow" — bold, `.headline` |
| **Secondary text** | Reason string — regular weight, `.caption` |

PWA equivalents: `background: #fffbeb`, `color: #92400e`, `border: 1px solid #fde68a` at `index.html`:2116–2118.

### State 3: ASP active today (confirmation)

| Property | Value |
|---|---|
| **Background** | `Color(UIColor.systemGreen).opacity(0.10)` — light mode ~#F0FDF4; dark mode system-adjusted |
| **Text color** | `Color(UIColor.systemGreen)` |
| **Border** | `Color(UIColor.systemGreen).opacity(0.35)`, 1pt |
| **Icon** | `checkmark.circle.fill` (SF Symbol — confirmation/success tier) |
| **Icon color** | `Color(UIColor.systemGreen)` |
| **Primary text** | "ASP in Effect Today" — bold, `.headline` |
| **Secondary text** | None. The green confirmation is self-contained. Adding "no suspension" text is redundant for any user who understands what the banner is for. |

PWA equivalent: `background: #f0fdf4`, `color: #166534`, `border: 1px solid #bbf7d0` at `index.html`:2125–2127.

### Positioning

**Top of screen, full-width, below the status bar — implemented via `.safeAreaInset(edge: .top)`.**

`ContentView` already applies `.ignoresSafeArea()` to the map (confirmed at `ios/WePark/WePark/ContentView.swift`:26). The correct way to add a banner that sits below the status bar without obscuring the map's usable area is:

```swift
Map(position: $cameraPosition) { ... }
    .ignoresSafeArea()
    .safeAreaInset(edge: .top, spacing: 0) {
        ASPBanner()
    }
```

`.safeAreaInset(edge: .top)` pins content below the status bar (including the Dynamic Island inset on iPhone 14 Pro+), pushes the map's rendered region down by the banner height, and adapts automatically to all device form factors and orientations. Do not use hardcoded `padding(.top, 44)` or a `ZStack` with manual offsets — these break on Dynamic Island devices and in landscape.

Reference: [safeAreaInset(edge:alignment:spacing:content:) — Apple Developer Documentation](https://developer.apple.com/documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)-6gwby)

### Dismissibility

**Sticky. No auto-dismiss. No user-dismiss affordance.**

The suspended/active state is factual parking information, not a transient notification. A user opening WePark to check whether ASP is suspended today does not want the answer to auto-dismiss after three seconds. The banner persists for the duration of the session. It recalculates on app foreground (ASPSuspensionService reads the current ET date on each foreground event — engineer note for W7).

The banner is compact (two lines maximum: primary text + secondary text + icon, all on one row in most cases). It does not block meaningful map interaction. If a real-world usage pattern surfaces in post-TestFlight feedback where the banner is actively obstructive, a swipe-to-collapse behavior can be added as a follow-up. For MVP, sticky is the correct default.

---

## 5. What this doc explicitly does NOT spec

These are deferred. Do not treat any of the following as implied work for W2/W7.

- **App icon design.** Later phase. A solid-color icon with a "W" lettermark satisfies AC-15 ("no Xcode placeholder") for TestFlight; full icon design is a separate engagement.
- **Launch screen / splash design.** Same phase as app icon.
- **Onboarding flow.** The TestFlight audience is Kevin and internal testers who know what the app does. Onboarding is a post-public-launch concern.
- **Pin marker design (My Car pin).** W5 work. Separate design deliverable: system `MapMarker` vs custom `MapAnnotation`, zoom behavior, selected vs unselected states.
- **Block detail sheet layout.** W4 work. Separate design deliverable: rule row layout, safety label type treatment, "Park here" button placement, scroll behavior on long rule lists.
- **Drive Mode visual styling.** Deferred per spec §2.2. Drive Mode on MapKit is a ground-up visual redesign that does not inherit directly from either this palette spec or the PWA's Mapbox aesthetic.
