# Curb-pin placement mode — design review — 2026-10-23

**Reviews:** `docs/longpress-universal-plant-spec.md`, "Amendment — fixed-center pin with live curb snap" (§A.0 rulings A-1/A-2, §A.3 interaction, §A.4 card, §A.5 legibility, §A.6 architecture).
**Stream:** B (design). Non-blocking for A1/A2; engineers ship their spec defaults and swap to the numbers here.
**Code reviewed for conventions:** `Services/ParkingColors.swift`, `Views/DriveModeBottomCard.swift` (TF2-18 chip anatomy), `Views/SpotPlacementView.swift` (existing card/banner + the "community blue" note), `Models/SafetyLabel.swift`. Placement-mode code does not exist yet, so this is a spec review, not a code review.
**Measurement caveat:** the dark MapKit basemap luminances below are estimates (no device in this session). Treat the ratios as design targets and re-measure on the Mac with a screenshot colour-picker. Nothing here is validated in direct sunlight; Kevin's outdoor check (§A.5) stays a flip prerequisite.
**HIG citations:** developer.apple.com HIG pages returned title-only to `WebFetch` this session, so the references are by URL from standing knowledge, not quoted: [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Motion](https://developer.apple.com/design/human-interface-guidelines/motion), [Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics), [Layout](https://developer.apple.com/design/human-interface-guidelines/layout), [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons).

---

## Summary

The spec's skeleton is right and I would not change its architecture: fixed needle, ghost + tether to the real curb, one opaque card, one primary button. Three things in it will hurt in the field and need fixing before the flag flips: (1) the pin sits at the exact bounds centre with an unbounded card below it, so Dynamic Type or an un-clamped zoom can put the card on top of the pin, ghost and highlight; (2) the mode is pan-only, with no non-pan way to move the pin, which makes it unusable under VoiceOver; (3) the highlight (white 14 / core 9) is invisible against a light basemap and the core colour is weak against its own casing. The rest of this doc is the exact-number spec that closes those and answers the five asks.

One design rule runs through everything: **chrome is monochrome (white, black, neutral grey); colour is data.** Needle, ghost, tether, casing, buttons, Cancel, hint pill and the "No curb here" state use only white/black/neutral. Green/orange/amber/red/grey appear only where they mean parking state: the curb core and the status chip. Nothing in the chrome is blue, red or orange, so nothing can be misread as a curb state.

---

## Specification (exact numbers for @ios-engineer)

All sizes are points. All fills opaque (alpha 1). Use text styles (`.title2`, `.headline`, ...), never `.system(size:)`, except inside the reticle drawing which is not text. Reference device 393x852 (safe top 59, bottom 34); the SE class (375x667, bottom safe 0) is the tight case and is checked below.

### 0. Geometry contract (the one change to §A.3)

Define a single `PlacementGeometry.tipPoint(in bounds: CGRect) -> CGPoint` used by the reticle, the resolver, the settle nudge and the card-clearance clamp:

- `tip.x = bounds.midX`
- `tip.y = bounds.minY + 0.40 * bounds.height`  (341 on 852; 267 on 667)

The pin ground coordinate is `mapView.convert(tipPoint, toCoordinateFrom: mapView)`, not `mapView.centerCoordinate`. The settle nudge computes the new map centre as `convert(screenPoint(of: snapped) + (boundsCenter - tipPoint), toCoordinateFrom:)`, then `setCenter`. This is ~10 extra lines and one helper. **Fallback if the engineer judges it too risky blind:** keep `tip = bounds centre` exactly as the spec says and apply the card-height cap and zoom floor in Finding 1; those alone keep the guarantees on 852-class phones but leave the SE-class tight.

Why 40%: on 852 it leaves 215 pt between tip and card top for the ghost's reach (24 m / 0.28 m/pt = 86 pt), puts the pin above the thumb's resting zone so the finger never hides it, and keeps the needle head (top at tip - 64) clear of the Cancel row.

### 1. Reticle

| Element | Spec |
|---|---|
| Needle | Head: 44 pt circle, fill `white`, 2 pt `black` outline (outer diameter 44). Stem: 20 pt tall, 4 pt wide at the head tapering to 1 pt at the tip, white fill, 1.5 pt black outline. Total height 64; tip is exactly `tipPoint`. Head glyph (optional, polish): SF Symbol `car.fill`, 20 pt, black, for intents `.park/.plant/.parkBlock`; `mappin` for `.report`. |
| Ground mark | A 12x5 black ellipse centred on `tipPoint` (the true ground point). Lifted state: 16x7. This, not the needle, is the honest location while the needle is lifted. |
| Lift | While a pan/pinch recognizer is active the needle translates up 8 pt; on settle it drops back (`UIView.animate` 0.12 s, spring damping 0.8). Ground mark enlarges but does not move. |
| Ghost | White-filled circle 16 pt, 2.5 pt black ring (21 pt outer), centred on the snapped curb point. Outer size deliberately exceeds the 20 pt highlight band so it reads as sitting on it. On settle it sits under the needle tip as a landing dot. |
| Tether | Two strokes: black 5 pt under white 3 pt, round caps, tip -> ghost centre. Hidden when length < 4 pt. Solid, never dashed (dashes shimmer at 30 Hz). |
| No-curb | Needle + ground mark only. Ghost, tether, highlight absent. Needle does not change colour. |
| Draw order | Highlight overlay (map) < tether < ghost < ground mark < needle (reticle view). Highlight overlay level `.aboveRoads` (same as curb lines) so street-name labels still draw above it. |
| Alpha | None. Shadow alpha is allowed (it is a shadow, not an element). Do not reuse `DraftSpotPinAnnotation` or `PendingParkPinAnnotation` looks. |

**Settle nudge refinements:** skip if the snapped point is < 2 pt from the tip on screen (nothing visible to settle). Duration `0.12 + 0.002 x distancePt` s, clamped 0.14-0.30 s (so an 86 pt jump is ~0.29 s rather than a jarring 0.18), ease-out. Start 100 ms after the map stops; if a touch begins during the dwell or the nudge, abandon it (the `isProgrammaticNudge` flag is cleared in `regionDidChange`).

**Reduce Motion** (`UIAccessibility.isReduceMotionEnabled`; observe `reduceMotionStatusDidChangeNotification`, do not cache at launch):
- Entry and exit camera moves: `animated: false`; reticle fades in over 0.15 s (opacity only) instead of the fly-in. Pitch/heading flatten is part of the non-animated set.
- Needle lift/drop: no translation. The ground mark still grows 12x5 -> 16x7 (instant) as the "you are moving" cue.
- Settle nudge: `animated: false` (instant jump of <= 86 pt; acceptable, no vestibular sweep).
- Tether length and ghost position are data, not decoration, and keep updating live.
- Hint pill and card text swaps: no fade, no slide (instant).

**Haptics** (HIG: only where they confirm something; not every tap):
- Commit ("Park here" / "Save car here"): `UINotificationFeedbackGenerator` `.success`, fired as the action runs.
- Blockface change during a user gesture: `UISelectionFeedbackGenerator.selectionChanged`, throttled to >= 150 ms, never for programmatic nudges. This is the glance-free confirmation that the highlight flipped sides. Recommended over cutting it (A.13-2 puts it first on the chopping block; I would cut the arrow chip first instead).
- Nothing on entry, nudge settle, Cancel or locate.

### 2. Snapped-blockface highlight

One overlay, one custom `MKPolylineRenderer` subclass that strokes four layers in a single `draw` (cheaper than four overlays and guarantees they cannot desync). Widths are in screen points; inside `draw(_:zoomScale:in:)` divide by `zoomScale`.

| Layer (bottom to top) | Width | Colour | Role |
|---|---|---|---|
| 1 outer keyline | 20 | `#000000` | Edge on light/tan/white map features |
| 2 casing | 16 | `#FFFFFF` | Edge on dark map and on the green/red curb lines |
| 3 inner keyline | 11 | `#000000` | Separates core colour from the white casing |
| 4 core | 8 | the blockface's current severity colour, **opaque** (`.unknown` -> `#8E8E93`, not the 0.35-alpha map value, which would vanish) | Meaning |

Ring thicknesses: black 2 / white 2.5 / black 1.5 per side. Line cap `.round`, join `.round`. Other curbs stay at normal opacity (spec's "do not dim data" is correct). Browse line is 4.5 pt, drive 8 pt, so a 20 pt band is unmistakable and still leaves 36 pt of clear map between the two curbs of a 15 m street at the entry zoom (54 pt apart).

**Why four layers rather than the spec's two (14 casing / 9 core).** White casing alone is 1.15:1 against the light tan basemap (L ~ 0.86): invisible. And a green core directly against white is only 2.0:1 (amber 1.7, orange 2.1). The black/white ring pair gives a max-contrast edge on every basemap and every curb colour, and the black inner keyline lifts the core off the white (green 10.4, orange 10.2, amber 12.2, red 6.2, grey 6.4 : 1). Any single feature the pair sits on, light or dark, is separated by at least one ring at >= 7:1.

**Zoom guard (polish):** if `metersPerPoint > 0.5` (user zoomed out), scale all four widths by 0.6 so the band cannot swallow the neighbouring curb (curbs fall under ~25 pt apart there).

#### Outdoor contrast math

Two columns. **Nominal** = WCAG `(L1 + 0.05)/(L2 + 0.05)`. **Glare** = `(L1 + v)/(L2 + v)` with `v` a screen-reflection veil as a fraction of peak white: v = 0.15 (bright shade / overcast), v = 0.50 (partial direct sun; real direct sun on glossy glass can be worse). This glare model is my engineering approximation, not a measurement, and is stated so the numbers are comparable, not so they are believed to the decimal. L values are relative luminance of the dark-scheme resolved colours (system red `#FF453A` 0.258, green `#30D158` 0.469, orange `#FF9F0A` 0.461, amber literal 0.561 with chip text `#261A00` 0.011, card `#1C1C1E` 0.0117, dark land est. 0.02, dark roads est. 0.045).

| Pair | Nominal | v 0.15 | v 0.50 | Verdict |
|---|---|---|---|---|
| White casing vs dark land / vs dark road | 15.0 / 11.1 | 6.8 / 5.9 | 2.9 / 2.8 | Good |
| Black keyline vs light tan (L 0.86) | 18.2 | 6.6 | 2.2 | Good (only exists to cover light features) |
| White ring vs black ring (the structural edge) | 21.0 | 7.7 | 3.0 | Ceiling: nothing can beat this |
| Core vs black inner keyline: green / amber / orange / red / grey | 10.4 / 12.2 / 10.2 / 6.2 / 6.4 | 4.1 / 4.7 / 4.1 / 2.7 / 3.5 | 1.9 / 2.1 / 1.9 / 1.5 / 1.9 | Colour is secondary; the ring pair carries conspicuity, the card text + status icon carry meaning |
| Needle white vs dark land / road | 15.0 / 11.1 | 6.8 / 5.9 | 2.9 / 2.8 | Good |
| Needle black outline vs light tan | 18.2 | 6.6 | 2.2 | Good |

Takeaway for the PR: **at v = 0.5 even ideal black-on-white is only 3.0:1, and every mid-luminance pair (red, grey, blue) falls under 2:1.** So anything the user must read in sun is built from the white/black pair, and colour is never the only carrier of state (see the status icon below).

### 3. Card

#### 3.1 Surface and position

- Docked to the bottom, full width, top corners 20 pt continuous radius, **opaque** `Color(.secondarySystemBackground)` (`#1C1C1E` dark) extended under the home indicator (`.ignoresSafeArea(.container, edges: .bottom)`); content respects the safe area. Not `.regularMaterial`, not `.ultraThinMaterial`, no `.opacity()`.
- Top edge: 1 pt `Color(.opaqueSeparator)` plus a black shadow (radius 12, y -2, alpha 0.5) so the card reads as a layer over the dark map (card vs dark basemap is ~1.0:1 without it).
- Horizontal content padding 16. Top padding 16. Gap above the home-indicator zone: 8 pt (card with link) or 16 pt (without), added to the system bottom inset. The primary button's bottom edge is therefore >= 42 pt from the screen bottom on notch phones, outside the system home-gesture strip.
- Not a sheet, not an `ActiveSheet` case (spec is right). No drag handle: nothing about it is draggable; a handle would invite a swipe that the map eats.
- The card shows one of four states with identical outer height (reserve rows, never let the card jump while the user pans): **snapped**, **loading**, **no-curb**, **far-curb** (snapped + footnote).

#### 3.2 Rows (Dynamic Type = Large; heights scale)

| # | Row | Font / colour | Notes |
|---|---|---|---|
| 1 | Title: `"Stanton St · South side"` | `.title2.weight(.bold)`, `Color(.label)` | One `Text`: street bold, ` · `, side semibold. `lineLimit(2)` (4 at accessibility sizes). `minimumScaleFactor` none. Instant swap, no animation. |
| 2 | Cross streets: `"between Bowery & Chrystie"` | `.subheadline`, regular, **`Color(.label)`** | Deliberately not `.secondary` (see math: `.secondary` on the card is 5.9:1 nominal and 2.9 / 1.6 under glare). Hierarchy comes from size and weight, not dimming. `lineLimit(2)`. This line is the anti-Makeway orientation guard; do not drop it at small heights. |
| 3 | Status chip (from `safetyLabel`) | `.headline` (17 semibold), text per TF2-18 (`.black`; metered `#261A00`) | Min height 44, padding 14 h / 10 v, radius 12 continuous, full width, solid severity fill (`ParkingColors.*`, no opacity). **Leading SF Symbol, same colour as text, so state never depends on hue alone:** free `checkmark.circle.fill`, comingSoon `clock.fill`, metered `parkingsign.circle.fill`, restricted `nosign`, unknown `questionmark.circle.fill`. Text is `safetyLabel.text` verbatim (A9). No `minimumScaleFactor`; wraps instead. Unknown chip fill is `Color(.systemGray4)` (`#3A3A3C`) with `Color(.label)` text: the shipped unknown chip (`secondarySystemGroupedBackground` + `.secondary`) is the same colour as this card and would be invisible. |
| 4 | Far-curb footnote (conditional) | `.footnote`, `Color(.label)`, leading `info.circle` | `"Nearest curb with data"` (drop the parentheses). Only when A.3's >15 m + no-opposite-side rule fires. Takes the place of the reserved row-2 slack; if no slack, card grows once (acceptable: this state is rare). |
| 5 | **Primary button** | `.headline.weight(.bold)`; fill `Color(.label)` (white in dark), label `Color(.systemBackground)` (black in dark) | `Capsule`, `minHeight 60` via `@ScaledMetric(relativeTo: .body)` (spec says >= 56; Kevin prefers roomy; 60 default), full width. Label per intent: `Park here` / `Next` / `Save car here`. Pressed: fill `#D1D1D6`, no scale under Reduce Motion. Disabled (Loading): fill `Color(.systemGray4)`, label `Color(.label)`, trailing `ProgressView`. |
| 6 | Link row (only `.plant` + `communityEnabled`, A-1) | `.body.weight(.medium)`, `Color(.label)`, trailing `chevron.right` (`.footnote`, `Color(.label)`) | Full width, `minHeight 48` (scaled), 1 pt `Color(.separator)` hairline above, **12 pt gap below the primary button** so a thumb aimed at Park cannot land on Report. Reads as a list row (HIG-native "this goes somewhere") without any colour. Label `Report something here`. |

Heights at Large on 393x852 (incl. 34 safe): with link 16+28+4+20+12+44+16+60+12+48+8+34 = **302** (card top y = 550); without link **250** (top y = 602). Locate button floats 12 pt above the card top (see 3.6).

#### 3.3 "No curb here" empty state

Same card, same outer height, rows swapped:

1. Title: `No curb here`, leading `mappin.slash` (`.title2`, `Color(.label)`). Neutral; not red, not orange, not the 0.35 unknown grey.
2. Subtitle: `Move the map until the pin is near a street`.
3. Row 3 slot: the **nearest-curb chip** if one exists within 100 m: capsule, `minHeight 44`, fill `Color(.systemGray4)`, `Color(.label)` text `.headline`, content `[arrow] Nearest curb 150 ft`. The arrow is `location.north.fill` rotated by (bearing to the curb minus `mapView.camera.heading`); recomputed on settle only. **Make it tappable** (44 pt target): animates the camera so the nearest curb point is under the tip, then the normal settle/snap takes over. It is a hint, not an alternatives list, so it does not violate A10. Distance: feet under US locale (`MeasurementFormatter`, `.providedUnit`, round to 10 ft), metres otherwise. If no curb within 100 m the slot shows nothing and the card keeps its height (spacer).
4. Primary button: Park intent `Save car here` (enabled); Report intent `Next` (enabled). **Copy change proposed:** put the "no parking info" fact in the card, not the button: row 2 becomes `No parking info here. You can still save your car.` when intent is `.park/.plant/.parkBlock`. The spec's `Save car here (no parking info)` wraps at larger text sizes and makes the primary label long to read at a stoplight. If the model owner prefers the spec string, it works; this is a copy preference, not a blocker.
5. Link row unchanged (`Report something here` stays for `.plant` + community; it works with `segment: nil`).

Loading state: title `Loading curbs…`, no subtitle, chip slot shows a 44 pt neutral skeleton (`systemGray4`, static, no shimmer) with `ProgressView`; primary disabled as above.

#### 3.4 Top chrome

- **Cancel:** 48 pt tall capsule, min 96 wide, opaque `Color(.secondarySystemBackground)`, 1 pt `opaqueSeparator`, `xmark` + `Cancel` (`.headline`, `Color(.label)`), leading 16, top = safeTop + 8. Text label instead of a bare X: at a glance "X" can mean "dismiss the card" vs "abandon placement"; "Cancel" is unambiguous and matches Spot-open's existing banner copy. Dynamic Type for this chip capped at `.accessibility1` (`.dynamicTypeSize(...DynamicTypeSize.accessibility1)`) so floating chrome cannot grow over the pin.
- **Hint pill** (first 3 entries per install via `UserDefaults`, then never; also hides on first pan): capsule, opaque `Color(.secondarySystemBackground)`, `.subheadline.weight(.semibold)` `Color(.label)`, text `Drag the map to place the pin`, 36 pt tall, bottom edge 12 pt above the needle head top (y 227-263 on 852). Not interactive, `accessibilityHidden(true)` (the VoiceOver summary carries the same content). Rationale: Spot-open taught "tap the curb"; this mode inverts it (the map moves), so the first use needs one line of affordance.

#### 3.5 Dynamic Type

- Everything uses text styles; heights use `@ScaledMetric`. Test at Large, XXXL, AX1, AX3, AX5.
- Through XXXL: layout as above.
- At accessibility sizes: title `lineLimit(4)`; chip text wraps (no scale-down); the **card gets a max height = `bounds.height - (tipY + 130)`** (381 pt on 852, 270 on 667, including the safe inset). Within that cap the text rows (1-4) sit in a `ScrollView` (`.scrollBounceBehavior(.basedOnSize)`) and the primary button and link row are pinned below it, never scrolled away. Cancel/hint/locate labels capped as above.
- Button and chip never truncate with an ellipsis.

#### 3.6 Placement relative to pin, safe area, reach (393x852)

```
y=0    +-----------------------------------+
       |  (status bar / Dynamic Island)    |  safeTop 59
y=67   | [x Cancel]                [compass]|  Cancel 48pt tall
y=123  |                                   |
y=227  |       ( Drag the map to place )   |  hint pill, first uses only
y=277  |              (  O  )              |  needle head 44
y=321  |                 |                 |  stem
y=341  |                 v  <- tip = pin   |  tipY = 0.40 H
       |        ~ ghost + tether reach ~   |  <= 86pt at entry zoom, 160 at zoom floor
y=437..|                                   |  clear space >= 113pt
y=496  |                          [ locate ]|  48x48, trailing 16, 12 above card
y=550  +===================================+  card top (community/plant); 602 without link
       | Stanton St · South side           |
       | between Bowery & Chrystie         |
       | [ checkmark  Free until Tue 8 AM ]|  chip 44
       | [           Park here            ]|  button 60, white fill
       | ---------------------------------- |
       |  Report something here          > |  link row 48
y=818  |                                   |  8 pad
y=852  +--- home indicator zone (34) -------+
```

- Nothing in the card or chrome sits within 100 pt below the tip; the ghost cannot be covered at entry zoom, and the zoom floor (Finding 1) keeps that true when zoomed in.
- **Reach:** the primary button's centre is at y ~ 788 (of 852), the natural thumb arc. Locate is bottom-right, right above the card, in the same zone and attached to the card top so it follows card height. The only top-reach control is Cancel (top-left, the worst corner for a right thumb); it is a rare action and top-leading Cancel is the platform convention, so accepted. Left-handed users get Park and the link full-width, so no mirroring is needed.
- SE class (375x667, tip 267, card with link ~ 268 so top y ~ 399): ghost reach 267 + 86 + 10 = 363 leaves 36 pt. Tight but valid; this is the strongest argument for the 40% anchor.
- **MapKit attribution:** the Apple logo and Legal link sit bottom-left of the map and the card would cover them. Set `mapView.layoutMargins.bottom = cardHeight + 8` when the card's measured height changes (not per frame), so the logo rides above the card.

### 4. VoiceOver for a pan-only interaction

Reading order (set with `accessibilitySortPriority`, top = read first):

1. **Cancel** — label `Cancel`, hint `Returns to the map without saving.`
2. **Spot summary** (one element, trait `.adjustable`, container for rows 1-3): label `Parking spot`, value `<canonical street>, <side>, between <A> and <B>. <safetyLabel.text>.` (expand abbreviations: "Stanton Street, South side, between Bowery and Chrystie Street. Free until Tuesday 8:00 AM."), hint `Swipe up or down to choose a nearby curb. Three-finger swipe pans the map.` In no-curb state value is `No curb here. Move the map until the pin is near a street.`; in loading `Loading curbs`.
3. **Park here** — label `Park here` (button), hint `Saves your car on <street>, <side>.` (`Save car here` / `Next` per intent; hint for Next `Opens report options for this spot.`). Disabled state exposes `.notEnabled`.
4. **Report something here** — label as shown, hint `Opens report options for this spot.`
5. **Locate me** — label `Centre on my location`, 48 pt.
6. **Nearest-curb chip** (when present, between 2 and 3) — label `Nearest curb is 150 feet north-east`, hint `Moves the pin there.`

The reticle and highlight drawing are `isAccessibilityElement = false` (decorative); the summary element is the pin's accessible face. The map view stays reachable for three-finger scrolling, but a VO user should not need it:

- **Adjustable action (the key feature):** `accessibilityIncrement()` / `accessibilityDecrement()` on the summary cycle the pin through the nearby blockfaces (every blockface the index finds within the 30 m release radius, sorted by distance then `blockfaceKey`, wrapping), each time moving the camera so that curb's foot point is under the tip (same path as the settle nudge, non-animated) and posting the announcement. This is an accessibility affordance only, invisible to sighted users, so it is consistent with "no alternatives list" (A10).
- **Custom actions** on the summary (polish, lower priority): `Move pin north / south / east / west` (10 m each, then the normal resolve + nudge), and `Jump to nearest curb` when in no-curb state.
- **Announcements:** on entry post `.screenChanged` focusing the summary element. On outcome change post `.announcement` with `"<street>, <side>. <status>."` or `"No curb here."`, **debounced 0.8 s after the last change and only if `blockfaceKey` differs from the last one announced** and no recognizer is active. Never announce per frame. After commit, the destination (car saved / report sheet) owns focus.
- Voice Control: button names are unique and match visible text (`Park here`, `Cancel`, `Report something here`). Switch Control users reach the same actions via the adjustable element.

---

## Findings

### 🔴 Blocking (fix before the flag flips)

**1. Card, pin, ghost and highlight can collide (geometry + Dynamic Type + zoom).**
- **Where:** spec §A.3 (tip at bounds centre, "no minimum" zoom) + §A.4 (card with no height bound) — will land in `Views/PlacementReticleView.swift`, `Views/CurbPlacementCard.swift`, `Views/MapViewRepresentable.swift` `setCameraZoomRange`.
- **What:** the ghost can be up to 24 m from the pin tip. At the entry zoom that is 86 pt, but with no zoom floor a user pinching in to 0.05 m/pt puts the ghost 480 pt away, behind the card. Independently, at accessibility Dynamic Type sizes the card (title wraps to 3-4 lines, chip wraps, button grows with `@ScaledMetric`) can exceed half the screen, covering the tip itself at bounds centre.
- **Why it matters:** the mode's whole value is "see which curb the pin will land on." If the ghost/tether/highlight or the pin is under an opaque card, the user is committing blind, which is the Makeway failure mode with extra steps. Accessibility-size users are hit hardest and are exactly who cannot recover by panning.
- **Suggested fix:** (a) adopt the 40% tip anchor (Spec §0); (b) set a minimum camera distance of ~0.55x the entry distance (~60 m visible width, >= 0.15 m/pt, so max ghost reach 160 pt) in the same `setCameraZoomRange` call; (c) cap the card at `bounds.height - (tipY + 130)` with the text rows scrolling and the button/link pinned (Spec 3.5). Verify with a UI test at AX1/AX3/AX5 on SE and 15-class sizes that the card frame's `minY > tipY + 100`.

**2. Pan-only interaction has no accessible alternative.**
- **Where:** spec §A.3 "Pan/pinch are the only gestures that matter"; no a11y section in §A.4/§A.5.
- **What:** moving a fixed pin by panning a map needs precise two-axis drags, which VoiceOver (three-finger scroll), Switch Control and Voice Control users cannot do reliably. The spec says "accessibilityLabel on every control" nowhere and has no adjustable/custom-action story.
- **Why it matters:** the highest-stakes action in the app (where your car is, hence which sweeping rules apply) would be unusable for these users; this is an HIG accessibility failure ([Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)), not polish.
- **Suggested fix:** Spec §4 in full: summary element with `.adjustable` trait cycling nearby blockfaces, debounced announcements, ordered labels/hints on Cancel/Park/Report/Locate. Add a manual VoiceOver pass to the Mac smoke list.

### 🟡 Significant

**3. Highlight reads on dark only, and the core is weak against its own casing.** `PlacementReticleView` / highlight renderer (A.5: white 14 / core 9). White casing is 1.15:1 on the light tan basemap and the green/amber/orange core is 1.7-2.1:1 against white. Adopt the 4-layer 20/16/11/8 renderer and the contrast table (Spec §2). Opaque `.unknown` core `#8E8E93`.

**4. System-blue prominent button fails the spec's own 4.5:1.** If the engineer uses `.buttonStyle(.borderedProminent)` with the default tint, white text on dark-mode system blue (`#0A84FF`) is 3.65:1 (also true of the existing Spot-open "Post it", `SpotPlacementView.swift:197`, noted for a separate follow-up). Use the monochrome `Color(.label)` fill / `Color(.systemBackground)` label (21:1, 7.7 under v 0.15) and keep blue out of this mode; this also keeps "community blue" meaning community.

**5. `.secondary` text and the unknown chip are the sun-worst case.** Spec A.4 uses `.secondary` for the far-curb note and the shipped chip pairs `.secondary` text with a fill equal to the card colour. Use `Color(.label)` everywhere on the card, `systemGray4` for the unknown/neutral fills (Spec 3.2).

**6. Red chip is the weakest state and also the most important.** Black text on red is 6.2:1 nominal and 2.7 / 1.5 under glare (green 4.1 / 1.9). Not fixable by recolouring (palette is sacred). Mitigations in the spec: 17 pt bold-weighted `.headline`, 44 pt chip, redundant `nosign` icon, wording "No parking". Add a red-chip item to Kevin's daylight checklist alongside the dark-scheme check.

**7. Card must not cover the Apple Maps logo / Legal link.** Bottom `layoutMargins` on the map when the card height changes (Spec 3.6).

**8. Card height must not vary while panning.** The spec updates the card on every blockface change; if row counts differ, the card (and the attached locate button and map margins) jump under the user's finger. Reserve rows per Spec 3.1; swap text instantly with no animation.

**9. Settle nudge is fixed 180 ms regardless of distance and has no abort.** Up to 86 pt of unrequested map motion after the finger lifts is the biggest "the map moved on me" risk. Distance-scaled duration, 2 pt skip, 100 ms dwell, abort on new touch (Spec §1). Reduce Motion = instant.

**10. Cancel as a bare 48 pt X, top-left only.** Ambiguous at a glance and the hardest reach. Labelled `Cancel` capsule (Spec 3.4); top-left stays (platform convention, rare action).

**11. Mode inversion needs one line of affordance.** Spot-open, block-select and the old long-press all taught "tap/press the map where"; here the map moves, not the pin. First-3-entries hint pill (Spec 3.4).

**12. `Save car here (no parking info)` primary label.** Long for a primary; wraps at larger sizes. Move the fact into the card body (Spec 3.3). Copy-only, optional.

### 🟢 Polish

- **13.** Highlight width scale 0.6 when `metersPerPoint > 0.5` (Spec §2).
- **14.** Optional head glyph `car.fill` / `mappin` per intent (Spec §1).
- **15.** Blockface-change selection haptic (keep it; cut the arrow chip first if scope is cut). Commit success haptic.
- **16.** Nearest-curb chip tappable (one-tap fix instead of a read-only hint).
- **17.** Expand abbreviations for VoiceOver values ("Street" for "St", "Avenue" for "Ave") via the existing canonical-name helper.
- **18.** Pressed/disabled button states specified so nothing relies on `.opacity()` (Spec 3.2 row 5).

### 💡 Out of scope (future)

- Landscape and iPad: card becomes a 360 pt leading side panel and the tip anchors to the remaining map area's centre. Portrait-only is assumed here.
- On-map edge arrow pointing to the nearest curb when it is off-screen (the card chip is the cheap version).
- Light-scheme verification of this mode (the app forces Dark; chrome uses semantic colours so it should invert, but is unvalidated).
- A first-class "explain this curb" disclosure (hours, sign photos) from the card, tied to the Cruise/goal-first work.
- A magnifier loupe for the snapped curb in very dense areas (divided avenues), if Mac testing shows the 8 pt hysteresis feels sticky.

---

## What's working

- **The fixed needle + ghost + tether concept is the right honest rendering.** Showing where the point *will* land, then actually landing it, is better than Makeway's address label and better than the old pick-from-list flow.
- **Street · side · cross streets · status is exactly the right information hierarchy.** The cross-street line is a good anti-address guard, and using `safetyLabel` verbatim keeps one status formatter in the app.
- **Opaque card, 56 pt+ primary, 48 pt chrome, "chip + black text" anatomy.** The A.5 instincts (reject `.regularMaterial`, reject dim pins, record contrast ratios, admit the dark-scheme sun check is unvalidated) are all correct; this doc only adds numbers.
- **Never dead-ends:** no-curb state still lets Park save and Report continue. Keep that.
- **A-1 ruling (Park here primary + one quiet Report link)** keeps a single primary button and does not regress the common action to two taps. The link-as-list-row treatment here keeps it quiet without colour.
- **Hysteresis in screen-space (8 pt x metres-per-point)** is zoom-invariant to the finger; no design change needed.
- **Chrome gating and the Cancel/commit camera-restore semantics** (restore pitch/heading/style on commit, full snapshot on cancel) mean the ambient screen never ends up in a strange camera state.

## Items for the Mac smoke checklist (design-specific)

1. Pin tip sits exactly on the 40% anchor; ghost collapses under it after the nudge on 15-class and SE-class.
2. AX1/AX3/AX5: card frame `minY > tipY + 100`, button and link visible without scrolling.
3. Pinch in to the zoom floor with the ghost at max reach: ghost, tether and highlight remain visible above the card.
4. Highlight visible on a light-coloured map feature (park, plaza) and over each of green/amber/orange/red curbs; screenshot and sample the ring colours.
5. VoiceOver: entry announcement, adjustable swipe cycles curbs, debounced announcement on pan, Park/Report/Cancel labels.
6. Reduce Motion on: no fly-in, no needle lift, instant nudge.
7. Kevin outdoors, dark scheme: needle, highlight band, card text, and in particular a red "No parking" chip.
