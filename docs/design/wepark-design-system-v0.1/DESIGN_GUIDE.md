# WePark design system — "Stoop, straight" (v0.1)

Bespoke language for the WePark iPhone app (NYC street parking), chosen from `WePark Directions.dc.html` option 2a.
Sources: `uploads/WePark-design-kit/BRIEF.md`, `FLOWS.md`, `screens/` (current app, context only).
Visual spec: `WePark Design System.dc.html`. Tokens: `styles.css` → `tokens/`.

## Three rules
1. **Facts are flat.** Verdicts, times, addresses and sign text sit on flat surfaces in plain words.
2. **Raised means press or earned.** A hard ink shadow under a piece means you can push it down (Park here, chosen goal, car token) or you earned it (karma, stickers). Nothing else is raised.
3. **Line style carries the answer.** Solid = park. Broken = don't. Colour backs it up, never alone.

## Content fundamentals
- Second person, sentence case, short. No exclamation marks or slang in facts.
- Facts: "Free until Mon 9:00 AM", "No parking", "Street cleaning at 7 AM", "In front of 50 E 1st St".
- Every "free" statement names its end time. Windows are written "from now until 7 AM tomorrow".
- Actions are verbs: "Park here", "Start driving", "I left", "Pass your spot", "Walk there".
- Neighborly moments may be warm: "Thanks, neighbor.", "Bodega Cat is waiting". Still no emoji.
- Left/right always spelled out: "Left side", "Right side".
- Not live: every trip-plan surface carries "Trip plan · not live".

## Visual foundations
- **Type:** Fredoka only (400/500/600/700). Sizes in `tokens/typography.css`. Verdicts never truncate; they wrap and the layout stacks at large Dynamic Type.
- **Colour:** cream paper, ink violet, taxi yellow for actions and rewards, green for park, coral dashed for don't, violet stripes for trip plan. Dark mode is ink-violet, not black.
- **Borders:** fact 1.5px ink; control 2.5px ink; raised 2.5–3px ink + hard shadow.
- **Elevation:** only one kind: hard offset shadow `0 Npx 0 ink` (3, 4 or 6px). No blur, no gradients, no glass.
- **Press:** the piece moves down by its shadow height and the shadow goes to 0. Spring back ~180ms.
- **Motion:** springs. Car token drops with one bounce; karma sticker pops and tilts 6°. Facts never animate except value changes.
- **Radii:** 16 chips/stickers, 20–24 tiles and cards, 30 sheet top, pill for buttons, 48 for drive side bubbles.
- **Spacing:** 4pt base (4, 8, 12, 16, 20, 24, 32). Screen margin 18.
- **Targets:** 48 minimum, 64 standard, 72–80 in drive mode.
- **Map:** Apple MapKit base, muted (POIs off). WePark draws curb lines and markers. The map is the calmest surface: no outlines on map chips except rewards and actions.
- **Layout:** drive mode puts left-side info on the left edge and right-side info on the right edge; the side you can park on is larger.

## Curb lines
- Default (two states): solid green = park for the window; dashed coral = don't.
- Detail mode ("Show all sign details"): solid green free; long-dash amber changes within window horizon; dotted blue metered; dashed coral no parking/standing; grey hairline no data.
- Unsure = drawn as don't.

## Iconography
No custom icon set drawn yet. Plan: SF Symbols, Rounded, Semibold (native to SwiftUI, matches Fredoka). Mocks use text labels or plain shapes where a symbol will go. Car token = yellow disc with ink car shape. No emoji. No logo was provided; the name is set in Fredoka 600.

## Index
- `WePark Directions.dc.html` — the three original directions (1a, 1b, 1c) and the chosen 2a.
- `WePark Design System.dc.html` — spec sheet.
- `tokens/` — colors, typography, shape.
