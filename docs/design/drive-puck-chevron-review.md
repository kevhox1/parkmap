# Drive Mode directional-glyph audit — "the black triangle isn't so clean" — 2026-10-20

## Summary

Kevin's "black triangle" is **not** the nav puck — that element was already rebuilt in build 23 (circle + white ring + white glyph) and reads correctly in the code. The strongest candidate is the **top-leading `MKCompassButton`**: a native, unstyled system control that is almost continuously visible during heading-up driving (its `.adaptive` visibility shows whenever the map is rotated off true north, which is nearly 100% of drive time), floats with no backdrop over the always-dark `.mutedStandard` map, and was *already flagged in the engineer's own code comment* as a risk nobody had seen on-device yet. The second candidate is the `chevron.forward` directional overlay drawn on `enforcement_active`/`sweeper_passed` community pins — a genuinely unchanged, pre-restyle glyph that is both tiny (9.6pt) and manually composited, making it the one element in this audit that actually fits "escaped the restyle." Both are concrete, fixable, and don't touch the puck's locked rotation contract or the 5-color curb palette.

## Inventory — every directional glyph reachable while `driveModeActive == true`

| # | Glyph | Where | Size / colors | Visible when |
|---|---|---|---|---|
| 1 | Nav puck (`location.north.fill` in filled circle + white ring) | `ios/WePark/WePark/Views/MapViewRepresentable.swift:554-604` (`driveNavPuckImage()`), applied `MapViewRepresentable.swift:2366-2395` | 44pt diameter (`driveNavPuckDiameter`, line 529), `.systemBlue` fill, white 3pt ring, white glyph at 45% of diameter, soft black 50%-alpha drop shadow (blur 4, offset y:1) | Always, while `driveModeActive == true` — this is "you are here" |
| 2 | **`MKCompassButton`** (system control) | Created unconditionally in `makeUIView`, `MapViewRepresentable.swift:1428-1436`; `showsCompass = false` on the map itself at line 1106 so this repositioned copy is the only one | System-rendered compass dial + needle, default MapKit styling (not recolorable by this app beyond backdrop/visibility) | `.compassVisibility = .adaptive` (line 1429) — shows whenever the map's heading ≠ true north. In heading-up Drive Mode this is true almost continuously (only briefly hidden if literally driving due north) |
| 3 | `chevron.forward` directional overlay on community pins | Composited in `ios/WePark/WePark/Views/PinMarkerAnnotation.swift:706-756` inside `markerImage(for:bearing:)`; bearing computed in `MapViewRepresentable.swift:2035-2055` (`resolveBearing`); pins synced unconditionally (not gated on drive/browse) in `MapViewRepresentable.swift:1979-2023` | 9.6pt (`imageSize * 0.30` on a 32pt circle), white, `weight: .bold`, drawn via manual `CGContext` rotate+translate, offset so it straddles the circle's own edge | Only when an `enforcement_active` or `sweeper_passed` crowd pin is within the loaded tile set near the route — intermittent, not constant |
| 4 | Destination pin (`mappin` glyph in `MKMarkerAnnotationView` balloon) | `MapViewRepresentable.swift:2398-2413` | System balloon shape, `.systemRed` tint, standard MapKit teardrop silhouette (has a small pointed tail at the bottom, not a filled triangle) | Whenever a destination is set (Destination Mode) |
| 5 | Parked-car pin (`car.fill` glyph in `MKMarkerAnnotationView` balloon) | `MapViewRepresentable.swift:2499-2530` | Same balloon silhouette, `.systemBlue` tint, `alpha = 1.0` | Whenever a car is parked and in viewport — independent of drive state |
| 6 | Draft-spot / pending-park pins (`mappin.and.ellipse` / `car.fill`, dimmed) | `MapViewRepresentable.swift:2422-2438`, `2448-2464` | Same balloon family, `.systemBlue`, `alpha = 0.85` | Community "Spot open" placement / resting long-press only — **not reachable while `driveModeActive == true`** (ruled out) |
| 7 | Bottom-dock icons: Recenter (`location.fill`), Report (`flag.fill`), Park Here (`mappin.and.ellipse`), End (`xmark.circle.fill`) | `ContentView.swift:2715-2759` (recenterButtonStack, hidden during drive), `2779-2794` (endDriveControl), `2812-2827` (recenterRow), `2845-2943` (driveActionRow) | All circles/capsules with SF Symbols; none are triangle/chevron/arrow glyphs | Various Drive-Mode-only rows — **ruled out**, no triangle shapes anywhere in this set |
| 8 | `DriveModeBottomCard` icons: `location.fill` (approach strip), `speaker.wave.2.fill`/`speaker.slash.fill` (mute) | `DriveModeBottomCard.swift:84-86`, `288` | Plain SF Symbols, no composition | Drive Mode bottom card — **ruled out**, no triangle shapes |
| 9 | Historical: `arrow.triangle.turn.up.right.diamond.fill` Drive-entry button | Was in `ContentView.swift` per `HANDOFF.md` W8.5b row | — | **Deleted** in FT-20 Stream C (`driveEntryButton` removed entirely) — does not exist in current code, ruled out |
| 10 | *(Out of app's code, flagged for completeness)* Apple basemap one-way-street arrow glyphs | Rendered by MapKit itself inside `.mutedStandard`/`MKStandardMapConfiguration(emphasisStyle: .muted)` vector tiles — not something this app draws | Apple's own road-furniture styling | Possible at tight drive-mode zoom (~621m altitude) on one-way Manhattan streets |

## Diagnosis

**Ruled out: the nav puck (#1).** Build 23 replaced the prior bare `location.north.fill` SF Symbol (which Kevin previously and separately called "the black arrow chevron sign," PR #107 gate, 2026-09-13) with a composed circle + white ring + white glyph + shadow, specifically to stop reading as a flat dark shape over the dark map. The code is correct: the shadow context is saved/restored around only the ring stroke, the circle fill and glyph are drawn after the shadow state is cleared, and there's no path in `driveNavPuckImage()` that would produce an unexpectedly dark or triangular result. If Kevin is looking at *this* element and still seeing a problem, that's a different bug (stale TestFlight build, or a live rendering regression) and deserves its own fresh screenshot — don't fold it into this fix.

**Primary candidate: the repositioned `MKCompassButton` (#2).** Three things point here:
1. **Persistence.** `compassVisibility = .adaptive` means it shows whenever the map is rotated off north — and Drive Mode's whole point is heading-up rotation. Unless Kevin is driving due north, the compass is on-screen for nearly the entire drive, which matches "the ~~black triangle~~ on the screen" (singular, persistent, not "a pin I drove past once").
2. **No backdrop, no restyle.** Every other floating control in this app (recenter, mute, report, End) got the `.regularMaterial` capsule/circle treatment. The compass is a bare system view with none of that — it's the one piece of Drive Mode chrome this app doesn't actually draw, so nobody could style it for the always-dark map.
3. **It's already flagged in the code as an open risk.** The comment at `MapViewRepresentable.swift:1420-1427` reads almost verbatim like Kevin's new complaint: *"if the bare compass reads as a 'foreign element'... once he sees it live, wrapping it in a show/hide-synced `.regularMaterial` backdrop is a scoped follow-up."* The compass needle itself is a two-tone system glyph (a north-pointing indicator paired with a darker counter-indicator) — exactly the kind of small, dark, pointed shape a driver glancing at the screen for a second would describe in plain language as "a black triangle," especially if it's also stuttering (see note below).
4. **Ties into the separate heading-lag complaint.** The compass needle's rotation is driven by the same camera `heading` value `syncDriveHeading` applies to the puck. If heading updates feel laggy (Kevin's other, engineering-owned note), the compass needle will visibly judder along with it — which reads as "not clean," reinforcing rather than contradicting this diagnosis. Not claiming causation, just noting the two complaints likely share a root signal.

**Secondary candidate, and the one that actually matches your "escaped the restyle" hint: the community-pin `chevron.forward` overlay (#3).** This compositing (`PinMarkerAnnotation.swift:706-756`) predates the puck restyle entirely — it's FT-11-era, well before the PR #107/#110 "match it to whatever Maps uses" fix, and nothing about that fix touched it. At 9.6pt (30% of a 32pt circle), drawn `.bold` white via manual `CGContext` rotation, and deliberately offset so it straddles the circle's own edge (`MapViewRepresentable`'s own doc comment: "place at 55% of radius from center so it overlaps the circle edge") — part of the glyph sits over the circle's colored fill and part sits over the fully transparent surrounding pixels. At this size, SF Symbol anti-aliasing is already marginal; straddling a hard edge between "colored fill" and "transparent" makes the chevron's silhouette genuinely harder to read cleanly, and a driver glancing briefly could easily perceive the muddier edge as a dark, not-clean wedge rather than a crisp white arrow. This is intermittent (only near enforcement/sweeper pins), so it's a good fit only if Kevin's drive happened to pass one — worth asking him directly.

**Noted but out of scope for @ios-engineer to "fix": Apple's own basemap one-way arrows (#10).** `.mutedStandard` at Drive Mode's tight zoom can render Apple's standard road-furniture glyphs (one-way arrows) directly on NYC's grid streets. This app has zero code path that draws these — there is no SF Symbol or custom rendering to change. If this turns out to be the actual culprit, the fix space is different (map configuration / POI filter experimentation, or living with it since Apple Maps itself shows the same thing) — flagging only so it isn't silently missed if the on-device check below rules out #2 and #3.

## Proposed fix per candidate

### A. `MKCompassButton` (primary)

Hide it specifically during Drive Mode rather than trying to restyle a system control's internals (MapKit doesn't expose the needle's colors). This also matches the reference standard named in this task: Apple Maps' own turn-by-turn view does not show a compass dial at all — heading-up rotation already tells the driver which way they're facing, and Apple relies on that instead of a redundant needle.

- Keep `compassVisibility = .adaptive` for browse mode (unchanged, still useful when the user manually rotates the map while not driving).
- Add a `weak var compassButton: MKCompassButton?` reference on `Coordinator`, captured right after creation in `makeUIView` (same place the reference is currently created, `MapViewRepresentable.swift:1428`).
- Add one more closure to `CoordinatorActions` (same pattern already used for every other Drive-Mode-boundary mutation in this file, e.g. `setShowsBuildings`):
  ```swift
  var setCompassHidden: ((Bool) -> Void)?
  ```
  wired in `makeUIView`:
  ```swift
  coordinatorActions.setCompassHidden = { [weak coordinator] hidden in
      coordinator?.compassButton?.isHidden = hidden
  }
  ```
- Call it from `ContentView`'s existing `.onChange(of: driveModeActive)` handler (`handleDriveModeAndCamera`), in the same batch as the other Drive-Mode-entry camera/style calls — e.g. `coordinatorActions.setCompassHidden?(active)`.
- This is not a camera mutation, so it carries no #31-class risk either way, but routing it through the same `.onChange`-driven `CoordinatorActions` path keeps it consistent with this file's own architectural discipline and keeps the change auditable alongside the other Drive-Mode-boundary toggles.

If Kevin would rather keep a compass visible while driving (some drivers like it), the fallback is: wrap it in the exact same `.regularMaterial` circle backdrop every other control already uses, sized to the existing 44×44pt family, which is the "scoped follow-up" the code's own comment already anticipated. Hiding it is the simpler, more Apple-Maps-faithful fix and is the recommended default.

### B. Community-pin `chevron.forward` overlay (secondary)

Two independent, additive changes to `PinMarkerAnnotation.swift`'s `markerImage(for:bearing:)` (lines 706-756) — neither touches the 5-color curb palette or any other pin type:

1. **Move the chevron fully onto the fill, not straddling the edge.** Reduce the outward offset from `imageSize * 0.22` to roughly `imageSize * 0.14` so the whole glyph sits inside the circle's colored background (teal for `enforcement_active`, cyan for `sweeper_passed`) instead of half-hanging over the transparent surround. This alone removes the hard color-boundary that's making the edge read as "not clean."
2. **Bump the glyph size slightly for legibility at drive-mode glance distance.** `chevronSize` from `imageSize * 0.30` (9.6pt) to `imageSize * 0.38` (~12.2pt) — still comfortably inside the "doesn't obscure the primary SF Symbol" intent the original comment calls out (AC-24), since it's moving inward (step 1) at the same time it grows.
3. Leave color (`.white`), weight (`.bold`), and the bearing-rotation math untouched — only position and size change.

### C. If the on-device check points at Apple's basemap (tertiary, likely no in-app fix)

No code change proposed here — flagging only. If Kevin confirms the shape is embedded in the road surface itself (moves/rotates with the street grid, not with the car or any UI element), escalate as a map-configuration question rather than a glyph bug: options are experimenting with `MKStandardMapConfiguration`'s `pointOfInterestFilter` (unlikely to affect road furniture, which isn't a POI) or accepting it as Apple's own rendering, same as stock Maps.

## Verify on device checklist (for Kevin)

1. **Start a Drive Mode session** (destination or Cruise) and drive/simulate on any street that isn't pointing exactly due north — i.e., almost any NYC block.
2. **Look at the top-leading corner of the screen** (just below the ASP banner). Is there a small circular control with a dark needle inside it? Does *that* read as "a black triangle, not clean"? This is the compass (#2) — candidate A above.
3. **If you pass an enforcement/sweeper report pin** (small teal or cyan circle), glance at it — does the small white arrow on its edge look crisp, or does it look like a muddy/dark sliver? This is candidate B above. A screenshot zoomed into that one pin would confirm instantly.
4. **Separately re-check the "you are here" puck itself** (blue circle, white ring, white arrow, right under your actual position) — confirm this one still looks clean post-build-23. If *this* is actually the element you mean, say so explicitly with a fresh screenshot — the code review above found no plausible rendering bug in it, so a persisting problem there would need a build-provenance check (is the TestFlight build you're on actually past build 23?) before any more glyph changes are made.
5. **Best single artifact:** a screenshot or 2-second screen recording taken at the exact moment the "black triangle" is on screen. Everything above is a reasoned hypothesis from code, not a pixel-level look at your actual device — one frame settles which of #2/#3/#10 it actually is.
