# Handoff: WePark design system v0.1 ("Stoop, straight")

## Overview
A new, bespoke visual and interaction language for the WePark iPhone app (NYC street parking, SwiftUI + MapKit). This package is the **design system only**: rules, tokens, parts, and three reference screens (main map, drive card, My Car). Full flow-by-flow screen redesigns come later and are not in this package.

## About the design files
The `.dc.html` files are **design references built in HTML**. They show the intended look and behaviour; they are not production code. The task is to **recreate this system in the existing SwiftUI codebase** using its own patterns (views, view modifiers, `ButtonStyle`s, asset-catalog colours), not to ship HTML.

Open the `.dc.html` files in a browser from this folder (they need the sibling `support.js`).

## Fidelity
**High-fidelity** for colours, type, radii, borders, shadows, wording and press behaviour. Two caveats:
- The map in the mocks is a simplified grid. The real base map is Apple MapKit, which can be muted (POIs off, light/dark) but not fully recoloured. Match curb lines and markers exactly; treat map base colours as a target, not a requirement.
- Icons are not drawn. Boxes labelled "symbol" are placeholders for SF Symbols (Rounded, Semibold).

## The three rules (apply to every screen)
1. **Facts are flat.** Verdicts, times, addresses and sign text sit on flat surfaces (1.5pt ink line, no shadow) in plain words.
2. **Raised means press or earned.** A hard offset shadow (no blur) under a piece means it can be pressed (Park here, the chosen goal tile, the car token) or was earned (karma, stickers). Nothing else has a shadow. There is no blur, gradient or glass anywhere.
3. **Line style carries the answer.** Solid = park. Broken = don't. Colour reinforces, never carries it alone. Unsure is drawn as don't.

## Design tokens
See `tokens/*.css` (source of truth) and `WeParkTokens.swift` (a SwiftUI starting point with the same values).

### Colour — light
| Token | Hex | Use |
|---|---|---|
| paper | #FBF6E6 | screen background |
| card | #FFFFFF | sheets, cards, rows |
| ink | #241F45 | text, lines, shadows, ink buttons |
| taxi | #FFD23F | things you press or earn only |
| park | #3CCF7A | "you can park" fills and curb line only |
| parkText | #17803F | green text on light surfaces |
| noParkLine | #E39A90 | dashed "don't" curb line and outlines |
| noParkText | #B8322A | red text, karma heart |
| muted | #5A5578 | secondary text |
| hairline | #A9A7B8 | no-data line, disabled border |
| divider | #E4E3EC | row dividers, off switch, map street |
| plan | #6A4CFF / stripe #5A3DF0 | trip plan (not live) only |
| detailSoon | #F2A23A | detail mode: free now, changes soon |
| detailMetered | #5B7CFA | detail mode: metered |
| mapBlock | #F5F1E6 | map block target colour |

### Colour — dark (drive mode and system dark)
bg #241F45 · surface #2E2856 · lifted #3F3870 · text #FBF6E6 · muted text #C3BFDC · line #6B64A0 · shadow #100D24 · noParkText #F5A79D. Taxi and park are unchanged. Text on taxi and on park is always ink #241F45.

### Type — Fredoka (Google Fonts, OFL; bundle the TTFs in the app), weights 400/500/600/700
| Style | Size / weight / line height | Use |
|---|---|---|
| verdict | 68 / 700 / 1.0 | drive-mode side verdict only |
| display | 44 / 700 / 1.05 | My Car end time |
| title1 | 34 / 600 / 1.1 | window end time on map sheet |
| title2 | 22 / 600 / 1.2 | addresses, primary button labels |
| headline | 18 / 600 / 1.25 | row titles, card titles |
| body | 16 / 400 / 1.4 | sentences |
| callout | 14 / 500 / 1.35 | supporting facts |
| caption | 13 / 400 / 1.35 | secondary lines |
| label | 12 / 600, caps, tracking 0.08em | "LEFT SIDE", section labels |

Map all styles to Dynamic Type (`relativeTo:`). Verdicts and times must never truncate: allow wrapping and stack layouts at accessibility sizes.

### Shape
- Radii: chip 16 · tile 20 · card 24 · sheet top 30 · drive side bubble 48 (inner corners only; the outer edge is flush with the screen edge) · buttons are capsules.
- Borders: fact 1.5 · control 2.5 · raised 3 (2.5 on small pieces). Always ink (dark: line colour for facts, ink/shadow for raised).
- Raise: hard shadow, y offset 3 (chips, stickers), 4 (tiles, medium buttons), 6 (Park here, large cards). Zero blur, colour ink (dark: #100D24).
- Spacing: 4, 8, 12, 16, 20, 24, 32. Screen margin 18.
- Touch targets: 48 minimum, 64 standard, 72–80 in drive mode.

## Interactions and behaviour
- **Press (raised pieces):** on touch down, translate Y by the shadow height and set shadow offset to 0; spring back on release, about 180 ms. Add a light haptic.
- **Press (flat pieces):** background shifts one step (white → paper, ink → #3F3870). No movement.
- **Goal tiles:** the selected tile is taxi, raised 4 and lifted 4 (translate Y −4). Unselected tiles are paper, flat, 2pt line. Selecting animates the swap and updates the window headline and the map.
- **Switch:** 56 × 34, 2.5 line, knob 22 with 2.5 line; on = park green, off = #E4E3EC; knob slides 23 in 180 ms.
- **Car token:** drag onto a curb; it snaps to the nearest curb and drops with one bounce. Once parked, the marker becomes flat (no shadow).
- **Stickers (karma, "Spot passed"):** pop in with a spring and settle at 6° (karma) or −5° (stamp) rotation.
- **Facts never animate** except a value change (cross-fade or number roll).
- **Drive mode:** left-side info hugs the left screen edge, right-side info hugs the right edge. The parkable side's bubble is larger (about 210 × 228, verdict 68pt); the other is smaller (about 156 × 160), filled #3F3870 with a 3pt dashed #E39A90 outline and white text. If both are parkable, both are large and green. Voice says the same words as the bubbles.
- **Trip plan (not live):** 4pt dashed #6A4CFF frame around the map plus a persistent striped tag "TRIP PLAN · NOT LIVE" with the visit dates. Park here, Report and Spot Pass are hidden.

## Curb lines (MapKit overlays)
- Default, two states: park = solid #3CCF7A, 6pt. Don't = dashed #E39A90, 6pt.
- "Show all sign details", five states: free = solid green · free now, changes soon = long dash #F2A23A (24 on / 8 off) · metered = dotted #5B7CFA · no parking or standing = dashed #E39A90 · no sign data = 2pt solid #A9A7B8.
- A shorter window must never show less green than a longer one (product rule 4 in `source/BRIEF.md`).

## Parts (see "Parts" in `WePark Design System.dc.html` for exact rendering)
- **Buttons:** Primary raised (taxi, 3 line, raise 6, height 80, label 28/700) · Medium raised (taxi, 2.5 line, raise 4, height 64, label 20/600) · Ink pill (ink fill, taxi or white label 22/600, height 64) · Secondary (white, 2.5 line, height 56, label 17/600) · Round (72 circle, white, 2.5 line, label 14/600) · Text link (15/600 underlined, 48 tall) · Disabled (#E4E3EC fill, #A9A7B8 line, muted label). One taxi button per screen.
- **Goal tiles:** 3 equal columns, gap 8, height 76, radius 20; name 15/600, "until …" 13/400.
- **Chips:** info chip flat (white, 1.5 line, height 48, 14/500) · selected option chip (ink fill, white 14/600) · unselected (2 line) · karma chip (taxi, 2.5 line, raise 3, 15/700, heart #B8322A).
- **Verdict blocks (radius 24, padding 16 × 18):** Park = green fill, "Free to stay until" 15/500, time 36–44/700, time-left bar (10 tall, white on ink), supporting line 14/500 · Don't = 3pt dashed #E39A90 outline, "No parking", reason and when it frees up · No data = 2pt #A9A7B8 outline, "No sign data", "Read the posted signs…" · Trip plan = 4pt dashed violet outline with the striped tag.
- **Rows:** min height 60, padding 8 × 16, title 16/600, subtitle 13/400 muted, 1pt #E4E3EC dividers, group has 1.5 line and radius 20.
- **Sheet:** white, top radius 30, 1.5 top line, no shadow.
- **Map markers:** you = 22 ink dot with 4 white ring · car token = 56 taxi disc, 3 line, raise 4 · parked car = 40 taxi disc, 2.5 line, flat · neighbor report = 44 rounded square (radius 14), white, 2.5 line · "leaving soon" = same square in taxi, raise 3.
- **Outside the app:** Live Activity = black, taxi token, countdown 30/700, "Leaving now" taxi capsule 56 tall · Dynamic Island compact = taxi token left, countdown in taxi right · Notifications use system type; the identity is wording: deadline first, then reason; actions "Walk there", "Remind me at 8 AM".

## Wording
- Facts: plain, sentence case, always with the end time. "Free until Mon 9:00 AM". "No parking. Street cleaning at 7 AM." "From now until 7 AM tomorrow".
- Actions: a verb. "Park here", "I left", "Pass your spot", "Walk there", "Start driving".
- Neighbor moments may be warm: "Thanks, neighbor.", "Bodega Cat is waiting for your spot."
- Never in facts: "Yes!", "Nope", "You're good", exclamation marks, "tonight" without a clock time, emoji.
- Always spell out "Left side" / "Right side".

## Reference screens (in `WePark Directions.dc.html`, section 2, option 2a)
Canvas is 375 × 812 pt.
- **Map:** full-bleed map; info chip top-left (48 tall); karma chip top-right; car token with hint bubble; bottom sheet with "Green curbs are free from now until" 13/500, end time 34/600, "8 h 49 min from now" 13/400, three goal tiles, ink "Start driving" button.
- **Drive (dark):** heading-up map; street-name and End capsules at top (52 tall, white); side bubbles from y≈396; bottom row: Report (72 round), Park here (80, raised), Voice (72 round).
- **My Car:** header (label 14/500 + address 22/600, Close 48 round); map strip 120 tall, radius 24, 1.5 line, parked-car marker at 28% from left, raised "Walk there · 4 min" chip bottom-right; green verdict block; reminder row with switch; taxi raised "Leaving soon? Pass your spot to a neighbor." card with "+5 karma" sticker; ink "I left" button; "See the 2 signs on this curb" link.
Options 1a, 1b, 1c in section 1 are earlier directions that were **not chosen**; ignore them for implementation.

## State
No new data requirements. The system only changes presentation. Existing state it reads: selected goal and window end, per-curb verdict for the window, drive-mode left/right verdicts, parked-car location/address/legal-until, reminder settings, karma count, trip-plan mode on/off.

## Assets
- Font: Fredoka (Google Fonts, SIL Open Font License).
- Icons: none yet. Use SF Symbols, Rounded, Semibold.
- No logo or app icon was provided; none is specified here.

## Open decisions (do not invent answers; ask the owner)
- Icon choices per feature.
- Logo and app icon.
- Detail-mode amber and blue have not been tested on the real map.
- "Walk there": in-app walking directions vs handing off to Apple Maps.

## Round 2
Every screen has since been designed with this system. See the sibling package `design_handoff_wepark_round2/` (keep the two folders side by side so the links in the spec sheet work). It also lists the parts added in v0.2.

## Files
- `screenshots/` — PNGs at 2x. Look at these first: `2a-map.png`, `2a-drive.png`, `2a-my-car.png` (the three reference screens, 375 × 812 pt plus device bezel) and `system-1-rules.png` … `system-8-wording.png` (each section of the spec sheet). Use the PNGs to see the design and this README for exact values; where they disagree, the README and `tokens/` win.
- `WePark Design System.dc.html` — the spec sheet (open first).
- `WePark Directions.dc.html` — reference screens (use option 2a only).
- `DESIGN_GUIDE.md` — the short written guide.
- `tokens/`, `styles.css` — CSS tokens.
- `WeParkTokens.swift` — SwiftUI starting point for the same tokens.
- `SKILL.md` — lets Claude Code load this folder as a skill.
- `source/BRIEF.md`, `source/FLOWS.md` — the owner's product brief and flows (hard requirements).
- `support.js` — runtime needed to open the `.dc.html` files; not part of the design.
