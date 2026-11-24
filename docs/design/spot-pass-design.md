# Spot Pass — design spec (stream E)

**Status:** Design spec for @ios-engineer (C1/C2/C3), @pwa-maintainer (D) and @backend-data (alias generator). Commissioned by `docs/specs/qr-spot-handoff.md` Revision 2, section 11. Date: 2026-11-23. Owner: @designer.

**Inputs honored:** Kevin ("make that code sexy and fun ... good neighbors ... building karma"; "an incredible first impression"; loved the lock-screen one-tap "Leaving now"; prefers big touch targets). Orchestrator rulings: alias + glyph by default with an opt-in "show my first name" (off); leave time capped at 4 h; auto-detect ships last behind its own flag and is not the hero; domain TBD (placeholder `getwepark.com`, short URL).

**Reads with:** `docs/design/first-run-onboarding-design.md` (monochrome chrome, `Color(.label)` primary buttons, code-drawn illustrations, Skip/Continue mechanics, haptic discipline) and `docs/design/goal-first-ambient-design.md` (sacred palette; More sheet rows; 56pt rail circles; "bigger targets" default).

**Final name:** **Spot Pass.** Tagline **"Pass the spot."** Verb is "pass" (a driver *passes* a spot; a seeker *gets passed* one). The ticket/badge metaphor is the visual idea: a small, friendly neighborhood pass, not a QR code with a logo.

---

## 0. Thesis, and the spec items the design shows are wrong or unbuildable

**Thesis (one sentence):** the badge is a *sign for a stranger*, the clip is a *thirty-second favor*, the Live Activity is the *one-tap payoff*, and karma is the *receipt*. Everything is designed so the person who has never heard of WePark understands it in two seconds and feels good about themselves at the end.

**Three design insights that change the build** (details in the sections):

1. **The badge's reader is the scanner, not the owner.** The seeker owns the phone; a walking stranger reads it. Headline copy, type size and the alias are written for someone 0.5-1 m away who has no context. The seeker's own controls sit *outside* the card.
2. **The alias is a human handshake.** The badge shows "Bodega Cat"; the clip then says "Bodega Cat is waiting for your spot." The driver sees the same words and glyph on both screens, so they know they scanned the right car. This is the cheapest trust device we have; keep alias+glyph large on both.
3. **Karma is shown as a receipt that lands, not a points meter.** Pending (dashed) becomes settled (solid) when the neighbor says thanks. That single animation is the emotional spine of the whole feature.

### 0.1 Flags against the spec (read before building)

| # | Spec location | Problem | Severity | Design response |
|---|---|---|---|---|
| F1 | §11 item 1, §14 "scans at 1.5 m through a tinted windshield" | **Not physically achievable with a phone-screen QR.** A phone is about 67 mm wide (iPhone 17) / 58 mm (SE). Even edge to edge, a 33-module code is 1.3-1.5 mm per module, about 45-50 mm wide. Phone cameras read reliably at roughly 10-15x the symbol width = **0.45-0.75 m**; 1 m is best-effort in clear light; 1.5 m through tinted glass will fail. | Blocking (acceptance criterion cannot pass) | Re-state the target as **0.5 m through glass / 0.8-1 m open air**, see section 1.5 for the test table. Add a "hold to the window" posture (section 1.6). |
| F2 | §1, §11 "phone in the mount ... through the windshield" | **A dash/windshield mount faces the driver; the screen faces away from the street.** A pedestrian outside the windshield sees the back of the phone. The only realistic scan is the seeker lowering the window (or pressing the phone to the side glass) and presenting the screen outward. | Blocking (changes the first-use copy and the flow) | Badge is designed for *presenting*, not mounting: "Hold me up to your window" first-use tip, a haptic and sound-free state change when scanned (seeker cannot see their own screen), brightness toggle for night. |
| F3 | §7.2, §11 "countdown ring" on the Live Activity | `ProgressView(timerInterval:)` self-animates in a Live Activity as a **linear bar**; I could not confirm a self-animating *circular* ring. A ring needs per-second pushes, which Live Activities do not get. | Significant (verify) | Design uses a **linear 6 pt bar**. Ring is used only inside the app's own badge, where we control redraw. |
| F4 | §3 "never a clock time" vs §11 "live countdown" | A seeker-side mm:ss countdown to departure **is** a clock time to the second and breaks the safety rule. | Significant | Seeker countdown is **only** for the unclaimed pass TTL (20 min, shown mm:ss). After arming, the seeker sees a **coarse band** ("about 30 min"), table in section 9.3. |
| F5 | §6.1 beat 5 "the clip's install overlay" with custom copy | `SKOverlay` (AppClipConfiguration) is a **system banner; its copy cannot be customized.** | Significant | Our own bottom card carries the copy and a "Get WePark" button that presents the `SKOverlay`. Section 8.1. |
| F6 | §6.1 beat 2 "next street cleaning on **their side**" + "green/red status in plain words" | (a) With When-In-Use accuracy of 5-65 m in NYC canyons and no heading, **side of street is a guess.** (b) The driver is *leaving*; a green "free here" claim about a block they are leaving is a legality claim with no value and real liability. (c) Green must never be decorative. | Significant | Show the **nearest curb by default with a one-tap "Wrong side?" switch**, never claim legality, use **red only when sweeping is active right now**, otherwise neutral. Section 3.5. |
| F7 | §6.1 "Now" chip | "Now" is ambiguous: *walking to the car now* vs *pulling out this second*. Sending `departed` on arm would ping the seeker while the driver is still on the sidewalk. | Significant | "Now" arms with `leave_at = now` and lands directly on the "Time to go?" state with the big pull-out button. It never sends the ping by itself. |
| F8 | §6.1 beat 5 vs §6.3 "install ask ... again with the thank-you ... never repeated within the session" | Internally contradictory. | Polish | Show once at celebration; if dismissed, not again in that launch. The thank-you push opens a *new* launch, which may show it once more. |
| F9 | §3 "rotates per pass, unlinked to username" vs §11 "karma tier chip" on the badge | A persistent, incrementing karma number on a badge strangers photograph **links successive passes to one person.** | Polish (privacy) | Badge shows a **bucketed** karma label ("New neighbor", "Helped a few", "Helped 10+", "25+", "50+", "100+"). Exact count stays inside the app. Section 2.4. |
| F10 | §11 "share image" mode | A shared image of a **live** QR leaks a single-use token. | Significant (safety) | No share image of the live badge, ever. Offer a **token-free "I passed a spot" karma card** after an outcome (section 7.6). |
| F11 | §2 Out "seeker-side Live Activity" | Seeker is likely in a navigation app after arming, so a lock-screen status is more valuable than "nice, not needed." But the coarse text needs ActivityKit pushes every 5 min (extra backend). | Out of MVP scope, flag | Designed in section 5.5, marked **Phase 2, recommend first fast-follow**. Push alert already covers the key moment. |
| F12 | §0 decision 2 name toggle | Needs a first-name source. Apple-sign-in users may have none. | Polish | Toggle disabled with a helper line when no first name exists. Section 9.1. |
| F13 | §10 karma tiers | Tier names ("Good Neighbor" layers) live in `docs/nyc-neighbors-incentives-concept.md`, which this spec does not restate. | Polish | Chip uses counts and the bucket labels above; swap labels for the concept doc's tier names once confirmed. |
| F14 | §5.1 "URL about 40 chars" | With a placeholder 13-char domain the URL is **48 bytes**, and the `#` forces QR byte mode. Fine, but the budget is real. | Polish | Hard limit **62 bytes** (QR v4-M, 33 modules). Domain must be at most 27 chars including TLD; a 10-char domain gives v3-L headroom. Section 1.5. |
| F15 | §7.2 compact Dynamic Island with a timer | `Text(timerInterval:)` shows `h:mm:ss` above 1 h and overflows the compact trailing slot. | Polish | Scale-to-fit rule in section 5.3 (`minimumScaleFactor`, monospaced digits). |

---

## 1. Visual language

### 1.1 Palette (green/orange/red are for curb meaning only)

Spot Pass needs its own identity without touching the sacred palette. **Spot Pass accent = system indigo.** Indigo appears nowhere in curb meaning, is distinct from the existing selection blue, and is warm enough to feel neighborly.

| Token | Value | Use | Contrast check |
|---|---|---|---|
| `passInk` | `#0E0F24` | Card/screen base, Live Activity tint | White on it about 19:1 |
| `passInkRaised` | `#1B1A4B` | Top of the card gradient (ink at the bottom) | White about 15:1 |
| `passIndigo` | `Color.indigo` (`#5E5CE6` dark / `#5856D6` light) | Primary action fill in Live Activity and clip; karma chip; ring | White on it 5.1-5.6:1 (passes 4.5) |
| `passLavender` | `#B8B5FF` | Secondary text and icons on ink | About 10:1 on ink |
| `passPaper` | `#FFFFFF` | QR plate, primary button fill on dark | n/a |
| `qrInk` | `#0B0B1E` | QR modules | 19.6:1 on paper (spec asks 7:1 min) |
| `qrEye` | `#3F3DB5` | Optional 3x3 center of each finder eye only | 8.2:1 on paper; far below the binarization threshold, safe |
| Glyph tints (alias) | indigo, blue, purple, slate-blue (4 tonal gradients) | Glyph disc behind the animal | White glyph on each at least 4.5:1 |

**Never used in Spot Pass chrome:** green, yellow, orange, red, teal, mint, cyan, pink (pink and mint read as red and green at a glance). Errors and ended states are neutral gray plus an SF Symbol, never red. The "spot opening up" and "Sent" states are indigo with a check glyph, **not green**: green means "legal to park here" and a celebration must not borrow it.

**Exceptions that are curb meaning, not decoration:** the clip's "This block" card (section 3.5) may use `ParkingColors.restrictedNow` for "street cleaning in effect right now". Nothing else.

**Confetti palette:** indigo, `passLavender`, white, sky `#7DB8FF`. No warm colors.

**Dark only.** Like the rest of the app, Spot Pass surfaces are dark-forced. The **QR plate is always white with `qrInk` modules in every appearance and every state**; never invert it.

### 1.2 Type ramp (SF Pro, system fonts, Dynamic Type)

All sizes are the default content size (Large). "Rounded" = `.system(style, design: .rounded)`: the friendly voice for alias, headlines and big numbers, still 100% native SF. Body/secondary text stays default design.

| Role | Style | Weight / design | Approx pt | AX behavior |
|---|---|---|---|---|
| Sign headline line 1 ("Leaving soon?") | custom `@ScaledMetric` base 34 | Heavy, rounded | 34 | **Capped at xxxLarge** (it is a physical sign for a stranger, section 2.3) |
| Sign headline line 2 | base 22 | Semibold, rounded | 22 | Capped at xxxLarge |
| Alias hero (clip) | `.largeTitle` | Bold, rounded | 34 | Scales to AX5, wraps up to 4 lines |
| Alias on badge | `.title` | Bold, rounded | 28 | Capped at xxxLarge on the card; full alias always in the VoiceOver label |
| Timer / big numerals | `.largeTitle` | Bold, rounded, `.monospacedDigit()` | 34 | Scales; Live Activity caps at AX1 (160 pt limit) |
| Section headline | `.title2` | Bold | 22 | Scales |
| Body | `.body` | Regular | 17 | Scales |
| Subline | `.title3` | Regular | 20 | Scales |
| Button label | `.headline` / `.title3` for the hero CTA | Semibold / Bold | 17 / 20 | Scales; buttons grow, never truncate |
| Caption / footnote | `.footnote` | Regular | 13 | Scales; **never `.caption2`** on any Spot Pass surface except the compact island timer |

Never `.system(size:)` except the sign headline (which uses `@ScaledMetric` so VoiceOver/AX users still get a sane layout).

### 1.3 Touch targets

Kevin's rule (default roomy, drive-mode surfaces biggest):

| Control | Min height |
|---|---|
| Hero CTA (clip "Tell ... when I leave", "Leaving now", "I'm pulling out", "Got it, thanks!") | **68 pt** (60 on SE) |
| Standard primary/secondary buttons | **56 pt** |
| Chips (leave time) | **56 pt**, min width 96 pt |
| Text buttons ("Not leaving", "Stop waiting", "Report") | visible 17 pt text, **44 x 44 pt minimum** hit area; **56 pt where they are the only safety exit** |
| Rail/utility circles | 56 pt |

### 1.4 Haptics (confirmations, not decoration)

| Moment | Haptic |
|---|---|
| Chip select | `.selection` |
| Tell-them CTA (arm) | `.impact(.medium)` |
| Seeker: pass scanned/armed | `.notification(.success)` (the seeker cannot see the screen when presenting it, F2) |
| Driver "Leaving now"/"I'm pulling out" sent | `.notification(.success)` |
| Celebration lands | one `.impact(.light)` at the stamp, one `.success` when karma settles |
| Seeker "Spot opening up" | `.notification(.success)` |
| Everything else (Stop waiting, Not leaving, close) | none |

### 1.5 QR requirements (the engineering contract)

The badge's one non-negotiable job is to decode. Everything below is a hard requirement with a test.

**Encoding**

| Parameter | Requirement |
|---|---|
| Payload | `https://<domain>/p#t=<22 base64url chars>` (spec §3). Byte mode (the `#` rules out alphanumeric mode). Placeholder `https://getwepark.com/p#t=...` = **48 bytes**. |
| **URL byte budget** | **At most 62 bytes** (fits version 4 at ECC M). Domain incl. TLD at most 27 chars. If the final domain is 10 chars or fewer the URL is at most 45 bytes and fits **v3 at ECC L (29 modules)**, which has bigger modules: take it if the center mark is dropped (see below). |
| **Version / ECC (default)** | **Version 4 (33 x 33 modules), ECC level M (15%).** |
| Fallback if a windshield test shows the mark hurts decode rate by more than 3 points | Drop the center mark entirely and keep v4-M, or use v3-L plain. Reliability beats brand. |
| Mask / ECI | Library default mask pattern. No ECI header. |
| Quiet zone | **4 modules on all sides** (QR spec minimum). The white plate IS the quiet zone: 41 x 41 modules. Nothing is drawn inside it: no text, no shadow, no sheen, no card border, no rounded-corner clipping closer than 4 modules to the symbol. |
| **Module size (screen)** | **8 pt = 24 px at 3x, an integer pixel multiple** (blur-free). Symbol 264 pt; plate 328 pt. Physical about 1.3 mm per module on iPhone 17, 1.25 mm on SE. |
| Rendering | Draw to a bitmap/`Canvas` at integer pixel boundaries. No `.blur`, no `.scaleEffect` animation on the plate, no `drawingGroup` resampling, no glass/material layer over it, ever. The plate does not animate; the card around it does. |

**Colors and contrast**

- Modules `qrInk` `#0B0B1E` on `#FFFFFF` = 19.6:1 (spec minimum 7:1; design target 12:1 or better after film/glare, which roughly halves contrast).
- **Dark-on-light only.** Inverted (light-on-dark) is not reliably read by the iOS Camera; never offer it.
- No gradient across modules. No translucency. The plate is opaque pure white.

**What decoration is safe**

| Decoration | Safe? | Rule |
|---|---|---|
| Rounded data modules | Yes | Corner radius at most 0.25 module, fill at least 92% of the cell. **Round dots/circles: not allowed** (too much white between modules; decode rate drops under glare). |
| Rounded finder eyes (the three big squares) | Yes | Keep the 1:1:3:1:1 ring ratio exactly. Round the **outer corners only** (radius at most 1 module). **No circular eyes.** |
| Color on the eyes | Yes, limited | Only the center 3 x 3 pupil may be `qrEye`; rings stay `qrInk`. |
| Center mark | Yes, tiny | **Exactly 5 x 5 modules, centered on module (16,16)** (about 2.3% of the symbol area, far under the 15% M can heal, leaving ECC for glare/dirt). White rounded square with 0.5 module padding holding the WePark pin glyph in `qrInk`. It does not touch the timing patterns (row/col 6) or the v4 alignment pattern (center 26,26, covers 24-28). |
| Larger center logo (more than 5 x 5) | **No.** | Would eat ECC budget needed for windshield glare. |
| Anything inside the quiet zone | **No.** | |
| Sheen, shimmer, pulse, glow over or behind the code | **No.** | Motion in the card chrome only. |
| Color tint on the plate | **No.** | Pure white. |

**Test table (QA, required before ship; `iPhone 12` or newer Camera app, plain vs branded rendered side by side):**

| Condition | Distance | Pass bar (decode within 1 s over 20 tries) |
|---|---|---|
| Open air, brightness 100% | 0.5 m | 100% |
| Open air, brightness 100% | 1.0 m | at least 90% |
| Through clear glass, 100% | 0.5 m | at least 95% |
| Through 35% side-window film, 100% | 0.5 m | at least 90% |
| Direct sun glare on plate, 100% | 0.5 m | at least 80% |
| 25 degree off-axis | 0.5 m | at least 90% |
| Brightness 70% ("Night" mode) | 0.5 m, dusk | at least 90% |
| **1.5 m (spec's original bar)** | | record only, expected to fail; not a gate |
| Branded vs plain delta | all rows | at most 3 points worse |

### 1.6 Two postures of the badge

1. **Mount posture.** Seeker glances at it; the screen is facing them. Everything below the QR is for the seeker.
2. **Present posture** ("Hold me up to the window"). The seeker holds the phone to the glass or out of the window, screen facing outward, and cannot see it. Therefore: (a) the badge never auto-locks (`isIdleTimerDisabled = true` while open), (b) brightness is forced up, (c) a **success haptic** tells them it was scanned (F2), (d) first-use copy teaches this posture (section 9.2).

---

## 2. The Spot Pass badge (seeker's full-screen pass)

### 2.1 Anatomy (iPhone 17: 402 x 874 pt, safe area top 62 / bottom 34)

```
+----------------------------------------------+
| Done                              [sun] 56pt |  top row 56pt. Done = text button, 44x56 hit.
|                                              |  Brightness = 56pt circle (Max / Night)
| +------------------------------------------+ |  card: 378 wide (12pt margins), radius 36 continuous
| | (pin) WePark              [heart] New    | |  header 56: wordmark .headline, karma chip right
| |                          neighbor        | |
| |  Leaving soon?                           | |  sign line 1: 34 heavy rounded, white
| |  Scan to pass me your spot.              | |  sign line 2: 22 semibold rounded, lavender
| |                                          | |
| |  +------------------------------------+  | |
| |  |  white plate 328 x 328, radius 20  |  | |  QR plate: quiet zone 32pt (4 modules) each side
| |  |  +------------------------------+  |  | |  symbol 264 = 33 modules x 8pt
| |  |  |      [ QR 33 x 33 ]          |  |  | |
| |  |  |         (5x5 pin mark)       |  |  | |
| |  |  +------------------------------+  |  | |
| |  +------------------------------------+  | |
| |                                          | |
| |  (cat)  Bodega Cat                       | |  glyph disc 52 + alias .title bold rounded
| |         Spot Pass  -  good for 19:42     | |  .subheadline lavender, timer text
| |  [=====================------]           | |  6pt linear progress (TTL) full card width - 40
| +------------------------------------------+ |
|                                              |
|  [          Stop waiting          ]  56pt   |  secondary, material fill, full width - 32
+----------------------------------------------+
```

Height budget (iPhone 17): top row 56 + card (56 header + 92 sign + 12 + 328 plate + 14 + 52 alias + 8 + 32 timer + 18 pad = 612) + 16 gap + Stop 56 = 740 of 778 usable. About 38 pt of slack. The QR **never** scrolls out of view at default sizes.

### 2.2 iPhone SE (375 x 667, no home indicator, status bar 20)

```
+--------------------------------------+
| Done                         [sun]   |  44
| +----------------------------------+ |  card 351 wide (12pt margins)
| |  Leaving soon?                   | |  sign 28 heavy / 20 semibold (SE scaled metric)
| |  Scan to pass me your spot.      | |
| |  +----------------------------+  | |
| |  |  plate 328 x 328           |  | |  same 8pt module (25pt side padding -> 11.5pt, plate flush w/ card padding 11.5)
| |  |  [ QR 33 x 33 ]            |  | |
| |  +----------------------------+  | |
| |  (cat) Bodega Cat   [heart] New  | |  karma chip moves into the alias row; WePark wordmark header dropped
| |  Good for 19:42  [=====---]      | |
| +----------------------------------+ |
| [        Stop waiting        ] 52    |
+--------------------------------------+
```
Height: 44 + (70 sign + 10 + 328 + 10 + 44 + 6 + 24 + 24 pad = 516) + 8 + 52 = 620 of 647 usable. Module stays 8 pt on SE (do not shrink the QR to fit; shrink chrome instead).

### 2.3 Copy (exact)

| Element | Copy |
|---|---|
| Sign line 1 | **Leaving soon?** |
| Sign line 2 | **Scan to pass me your spot.** |
| Wordmark | WePark (pin glyph + name, `.headline`) |
| Alias line | Bodega Cat |
| Sub | Spot Pass · good for 19:42 |
| Name-on variant | Maya (alias hidden; glyph kept). Sign line 2 unchanged ("pass **me** your spot" works for both) |
| Stop button | Stop waiting |
| Brightness toggle | sun icon, label VoiceOver only |

**Why a sign headline in a capped size:** the headline is read by a stranger at 0.5-1 m; physical size matters more than the seeker's Dynamic Type setting. It is capped at `xxxLarge` via `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` on that block only. Everything the seeker reads (timer, buttons, tip) scales to AX5 (section 2.7). The full text is always in the VoiceOver label.

### 2.4 Karma chip (bucketed, F9)

A 36 pt capsule, `heart.fill` (**indigo/lavender, never red**) + label, `passIndigo.opacity(0.25)` fill, 1 pt lavender border at 40%. Label buckets: 0 = "New neighbor"; 1-9 = "Helped a few"; 10-24 = "Helped 10+"; 25-49 = "Helped 25+"; 50-99 = "Helped 50+"; 100+ = "Helped 100+". Exact count is visible only inside the app's own screens (section 9). Swap labels for the incentives-concept tier names when confirmed (F13).

### 2.5 States (same layout, plate content changes)

| State | Header sign | Plate | Bottom row | Haptic |
|---|---|---|---|---|
| **Open (created)** | "Leaving soon? / Scan to pass me your spot." | Live QR | "Spot Pass · good for 19:42" + TTL bar. Under 2 min: "Ends in 1:12" bold, bar turns white to indigo-lavender pulse; no red. | none |
| **Scanned, arming** (brief, under 2 s while server confirms) | unchanged | QR dims to 30% + spinner centered | "A neighbor scanned. Hang on." | none |
| **Armed** | "A neighbor's on it." / "Leaving in about 30 min." | QR **replaced** by a 220 pt glyph disc (alias glyph, tint) with a check seal; plate stays 328 pt so nothing jumps; **a dead QR must not stay visible** (a second scanner would get "already used") | "It's a courtesy, not a promise." | `.success` |
| **Departed (spot opening)** | "Spot opening up." / "Your neighbor is pulling out now." | Glyph disc pulses; two ripple rings | Two big buttons replace Stop: [Got it, thanks!] [Didn't work out] (section 9.4) | `.success` |
| **Expired (unclaimed 20 min)** | "Pass ended." | Plate gray, QR removed, lock-style `clock.badge.xmark` glyph | [Make a new pass] primary 56, [Done] | none |
| **Cancelled (driver, silent)** | shows as **Expired**-like "Pass ended." (no reason, spec §3) | same | same | none |

The armed state's coarse text bands are in section 9.3.

### 2.6 Brightness, screen wake, orientation

- On appear (and each `scenePhase == .active`), store the current brightness and ramp to 1.0 over 0.25 s using the window scene's screen (`UIScreen.main` is deprecated for scenes; use `view.window?.windowScene?.screen.brightness`).
- **Restore** the stored value on: pass leaves `created` (armed/expired/cancelled), view disappears, `scenePhase != .active`, outcome sheet. Reapply on return to the foreground if the pass is still `created`.
- Do not fight manual changes: after 2 s of boost, if the user drags the slider, respect it until the next appear.
- **Night mode** (sun-icon toggle, persisted): 70% brightness. Rationale: 100% brightness on a 328 pt white plate in a dark cabin glares the driver. Test table row "Brightness 70%" must pass. First-use after dark: nothing automatic (we do not read ambient light), the tip line below the plate reads "Too bright? Tap the sun." only when local time is between 8 pm and 6 am.
- `isIdleTimerDisabled = true` while state is `created`; restore after.
- Rotation: card stays centered and scales *down only the chrome*; plate remains 328 pt. In landscape (height 402): hide the header row and the Stop button moves into a trailing 56 pt column; plate stays 328 (fits 402 minus the top inset on iPhone 17; on SE landscape height 375 the plate is 328 with 23 pt slack, header hidden, sign shrinks to one line "Leaving soon? Scan to pass me your spot." at 20 pt to the side of the plate).

### 2.7 Dynamic Type up to AX5 (badge)

- Sign headline: capped at xxxLarge (section 2.3). Alias row: capped xxxLarge on the card.
- At `isAccessibilitySize`: the screen becomes a `ScrollView` with the **card first** (QR is always the first thing; it must never be pushed below the fold by large text). Seeker-facing rows below the card (timer, "Stop waiting", Night toggle, tip) scale to AX5 and stack vertically.
- "Stop waiting" is a pinned `.safeAreaInset(edge: .bottom)` button at every size (56 pt, grows with type).
- Karma chip at AX: hides its label and shows only the heart + a number badge; the full label stays in VoiceOver.

### 2.8 Compact card (map sheet / Cruise) when the pass is live but the badge is closed

```
+----------------------------------------------+
| (cat)  Spot Pass is live        [ Show QR ]  |  card, 72pt min, material
|        Good for 12:04                         |  .subheadline; armed: "Neighbor leaving in about 30 min"
+----------------------------------------------+
```
`Show QR` = 56 pt prominent button (indigo fill, white label) reopens the full badge. Also a small `Stop` is **not** shown here (avoid accidental stop on the map); stopping lives in the badge.

### 2.9 Motion (with Reduce Motion fallbacks)

| Element | Motion | Reduce Motion |
|---|---|---|
| Card enter | translateY +24 to 0, scale .98 to 1, opacity 0 to 1, spring(response .45, damping .85); **plate is composited at final scale before the card moves** so it is always decodable (the camera may catch it mid-animation) | 0.2 s crossfade |
| Border sheen | One 0.9 s gradient sweep along the card border on appear (never over the plate) | none |
| Waiting pulse | Glyph disc ring scale 1.0 to 1.12, opacity .5 to 0, 2.4 s loop, only on the alias row glyph | static ring |
| Scan to armed | QR cross-dissolves to glyph disc 0.35 s; two ripple rings from the disc, 1.2 s | crossfade only |
| TTL bar | Linear, driven by `ProgressView(timerInterval:)` (no polling) | same (not decorative) |

### 2.9 VoiceOver (badge)

| Element | Label | Hint / traits |
|---|---|---|
| Card (grouped container, `.accessibilityElement(children: .contain)`) | "Spot Pass for Bodega Cat. Good for 19 minutes 42 seconds." | |
| QR plate | "Spot Pass QR code. Show it to a neighbor who is leaving so they can scan it with their camera." | `.isImage` |
| Karma chip | "Karma: new neighbor" | |
| Alias row | "Bodega Cat, cat glyph" | |
| Done | "Done" | hint "Closes the pass screen. Your Spot Pass stays active." |
| Stop waiting | "Stop waiting" | hint "Ends your Spot Pass. A neighbor who scanned will not be told." |
| Brightness | "Screen brightness: maximum" / "Night" | `.isButton`; value announces the new mode |
| State change to armed | `UIAccessibility.post(.announcement, "A neighbor scanned. Leaving in about 30 minutes.")` | |
| State change to departed | announcement "Spot opening up. Your neighbor is pulling out now." | |
| Blind/low-vision alternative (no aiming a QR) | Toolbar "Share link" (`ShareLink`) available **only to VoiceOver users** and via long-press on the plate: shares the same pass URL to a neighbor by AirDrop/Messages | Not in the visible UI by default; see 💡 section 12 |

---

## 3. App Clip: the card and the first screen

### 3.1 Beat 0, the Apple card (static, cannot be personalized)

The iOS Camera shows Apple's card, built from App Store Connect. **It is static: no alias, no name, no state.** Our copy has to work for every scan.

| Field | Limit | Copy | Count |
|---|---|---|---|
| Title | at most 30 | **Pass your spot to a neighbor** | 28 |
| Subtitle | at most 56 | **Tell them when you're leaving. No sign-up needed.** | 49 |
| CTA verb | Open / View / Play | **Open** | |

(Spec §5.3 default copy "Pass the spot" / "Tell a neighbor when you're leaving" is replaced: the new subtitle states the two things a stranger's brain asks first, *what do I do* and *do I have to sign up*.)

**Header image** (3000 x 2000 px, PNG/JPEG, sRGB or P3, no transparency; Apple crops it, so keep the subject inside the **center 2400 x 1200** and put **no text** in the art, because Apple overlays text and downsamples it small):

- Background: night gradient `passInk` to `passInkRaised`, a few tiny stars.
- A skyline of brownstone stoops in a slightly lighter ink, low across the bottom third.
- Center: a tilted (about 8 degrees) Spot Pass ticket, the badge card at hero scale, with a **non-functional abstract pattern** instead of a real QR (a real-looking QR in marketing art invites scans of a dead code), the pin glyph, and a lavender glow.
- A thin dashed lavender arc running from the ticket to the lower left (the "handoff").
- No green, red, orange, or yellow.

### 3.2 First screen, the moment (402 x 874)

Full-bleed `passInk` to `passIndigo.opacity(0.55)` vertical gradient. No nav bar (clips have none). Content in a `ScrollView` with the CTA **pinned** at the bottom.

```
+----------------------------------------------+
|  (pin) WePark                       [flag]   |  row 32: wordmark; flag = Report (44x44, quiet)
|                                              |
|              +-----------+                   |
|              |   (cat)   |  96pt glyph disc  |  gentle float (see 3.7)
|              +-----------+                   |
|                                              |
|     Bodega Cat is waiting                    |  .largeTitle bold rounded, white, centered
|     for your spot.                           |
|                                              |
|  Leaving soon? Tell them when, with one      |  .title3, lavender
|  tap. They'll only know you're pulling out,  |
|  never who you are or where you are.         |
|                                              |
|  When are you leaving?                       |  .headline white
|  [ Now ][ 10 min ][ 30 min ]                 |  chips 56pt high, 3 across
|  [ 1 hr ][   Pick a time   ]                 |
|                                              |
|  +----------------------------------------+  |
|  |  Tell Bodega Cat when I leave          |  |  CTA 68pt, white fill, ink label, .title3 bold
|  +----------------------------------------+  |
|   One tap. That's all they'll know.          |  .footnote lavender, centered
|        Not leaving soon                      |  44pt text button
+----------------------------------------------+
```

Sizing (iPhone 17): about 770 pt of content in 874. At default sizes nothing scrolls.

**SE (375 x 667):** glyph disc 64; headline 28; subline 2-3 lines at `.callout`; chips 52 high; CTA 60 high; reassurance lines collapse to the one footnote. About 556 pt of content in 647. Same order. CTA pinned.

### 3.3 Copy (exact)

| Element | Copy |
|---|---|
| Headline (alias) | **Bodega Cat is waiting for your spot.** |
| Headline (name-on) | **Maya is waiting for your spot.** |
| Headline (before peek returns, never blocks) | **A neighbor is waiting for your spot.** (crossfades to the alias, 0.25 s) |
| Subline | **Leaving soon? Tell them when, with one tap. They'll only know you're pulling out, never who you are or where you are.** |
| Chip label | **When are you leaving?** |
| Chips | **Now** · **10 min** · **30 min** · **1 hr** · **Pick a time** (selected: **10 min** preselected) |
| CTA, by chip | 10 / 30 / 1 hr / custom: **Tell Bodega Cat when I leave** · Now: **Tell Bodega Cat I'm on my way** (F7) |
| Under CTA | **One tap. That's all they'll know.** |
| Quiet button | **Not leaving soon** (closes with "No worries. Thanks for looking.") |
| Report | `flag` icon, VO "Report this pass" |
| Consent line (spec §9 item 1, shown inline above the CTA at AX sizes, below the chips otherwise) | **A neighbor will be told when you pull out. That's all they will know.** |

Chip rules: selected = **white fill, ink label, plus a leading `checkmark.circle.fill`** (not color alone); unselected = `white.opacity(0.14)` fill, white label, 1 pt `white.opacity(0.25)` border. Chips are **not** blue (blue vanishes on indigo; monochrome white is the app's own primary idiom).

**Pick a time:** sheet (`.medium` detent) with a native wheel `DatePicker` of time-only, `in: now...now+4h`, rounding to 5 min, title "Pick a time", helper "Up to 4 hours from now.", button **Set time** (56). Past the cap it simply cannot be selected (no error copy needed).

### 3.4 Armed state of the same screen ("You're on")

After the CTA, the screen morphs in place (no navigation, no spinner longer than 400 ms):

```
+----------------------------------------------+
|  (pin) WePark                                |
|              (cat) with a check seal         |  glyph disc "stamps" a seal (3.7)
|     You're on, neighbor.                     |  .largeTitle
|  We'll tell Bodega Cat when you leave        |  .title3
|  in about 10 min.                            |
|  +----------------------------------------+  |
|  |  Look at your lock screen              |  |  card: mini Live Activity illustration
|  |  [ 9:42 ]  [ Leaving now ]             |  |  + caption: "Tap it when you pull out."
|  +----------------------------------------+  |
|  +----------------------------------------+  |
|  | Curious about this block?  [ Show me ] |  |  the earned ask (3.5), 64pt row
|  +----------------------------------------+  |
|        Not leaving after all                 |  44pt min, quiet; ALWAYS visible (safety item 3/12)
+----------------------------------------------+
```

| Element | Copy |
|---|---|
| Headline | **You're on, neighbor.** |
| Sub | **We'll tell Bodega Cat when you leave. Reminder at 4:15 PM.** (the driver sees the real clock time; the seeker never does) |
| Lock-screen card title | **Look at your lock screen** |
| Lock-screen card body | **Your countdown is there, with a Leaving now button for when you pull out.** |
| If Live Activities are off | **Lock-screen countdown is off. We'll remind you with a notification instead.** with a `Settings` link |
| If ephemeral reminders are off | **Reminders are off. Your lock-screen countdown still works.** |
| If both are off | **Keep this screen handy. Tap "I'm pulling out" when you go.** and the pulling-out button becomes the primary on this screen |
| Cancel | **Not leaving after all** (confirm sheet, 56 pt buttons: **Cancel my pass** / **Keep it**) |

### 3.5 The earned reveal: "Show me this block"

Copy for the trigger row: **Curious about this block?** / sub **See what WePark knows about the street you're on.** / button **Show me** (56 pt, outlined white). Beneath it, one footnote **Uses your location once. Only a rough area is looked up, and nothing is saved.** (This is true per spec §5.2 item 3: only a coarse tile id leaves the device; confirm with @ios-engineer before shipping the copy.)

Purpose string (clip `NSLocationWhenInUseUsageDescription`): **"WePark uses your location once to look up the parking rules for the block you're standing on."**

Result card (replaces the trigger row):

```
+----------------------------------------------+
| This block                                   |  .title3 bold
|                                              |
|  Street cleaning on this side                |  .subheadline lavender; "nearest curb" caption
|  Tuesday, 8:00 - 9:30 AM                     |  .title2 bold white
|  Next: Tue, Dec 2                            |  .subheadline
|                                              |
|  Wrong side? Switch                          |  44pt text button, flips to the other curb
|  ------------------------------------------  |
|  Always check the posted signs.              |  .footnote
+----------------------------------------------+
```

| Case | Copy / treatment |
|---|---|
| Normal | **Street cleaning on this side** / **Tuesday, 8:00 - 9:30 AM** / **Next: Tue, Dec 2** |
| Cleaning in effect right now (the *only* colored state) | Pill with `ParkingColors.restrictedNow` fill + `exclamationmark.octagon.fill`, label **Street cleaning is happening on this side right now.** The pill is the sole use of red anywhere in Spot Pass, and it is true curb meaning. |
| Suspended today (if the evaluator can say so) | **Street cleaning is suspended today.** neutral gray pill with `pause.circle.fill`. No color. |
| No rule found | **We don't have a street-cleaning rule for this block yet.** with `questionmark.circle` neutral |
| Side ambiguity (F6) | Caption under the title: **Nearest curb.** + the **Wrong side? Switch** button |
| Location denied | Row simply disappears from the screen (no nag). Footnote **No problem. You can look up any block in the full app.** shown once in its place, no button. |
| Fetch failed | **Couldn't load this block.** + **Try again** (44 pt) |

**Never in this card:** "free", "legal", "safe to park", a green fill, or the words "your car" (we do not know where their car is; copy says "this block" and "this side"). Neighboring copy adds one forward link, quietly: **Next time you park here, WePark tells you this before you walk away.** (`.footnote`). That reframes the value for a person who is *leaving* the block (F6 b).

### 3.6 Pulling-out screen (clip target of the Live Activity link and the reminder)

The driver is at or in their car. One decision, huge target, and a calm safety line.

```
+----------------------------------------------+
|                 Leaving in  4:12             |  .title2 monospaced; or "Time to go?" at 0
|                                              |
|     (cat) Bodega Cat is waiting              |  glyph 72 + .title3
|                                              |
|  +----------------------------------------+  |
|  |                                        |  |
|  |            I'm pulling out             |  |  hero button 120pt high, white fill, ink label .title bold
|  |                                        |  |
|  +----------------------------------------+  |
|                                              |
|  Tap right before you go. Please don't use   |  .footnote lavender
|  your phone while driving.                   |
|                                              |
|   [ 5 more min ]          [ Not leaving ]    |  two 56pt secondary buttons side by side
+----------------------------------------------+
```

After tap: button swaps to a check seal and **Sent. Bodega Cat knows you're pulling out. Drive safe.** for 1.2 s, then transitions to the celebration (section 7.1). Haptic `.success`. If the call fails: **Couldn't send. Try again.** (button returns, no state lost).

If `Now` was chosen, the screen **opens here** (F7) with the headline "Time to go?" and a live timer of 0:00 omitted.

### 3.7 Motion (clip)

| Element | Motion | Reduce Motion |
|---|---|---|
| Launch to first screen | Gradient + glyph visible at frame 1 (static); alias text crossfade 0.25 s | same (opacity only) |
| Glyph disc | Idle float: translateY +-4 pt, 3.2 s ease-in-out, plus a soft glow | static |
| Chip select | scale .97 then 1.0, 0.15 s; `.selection` haptic | no scale |
| Arm | Disc scales 1.0 to 1.08 to 1.0 with the seal appearing (spring 0.4); headline crossfade | seal fades in, no scale |
| Reveal card in | slide up 16 pt + fade 0.3 s | fade only |

### 3.8 Skeleton, slow, offline

- **Under 1 s:** glyph disc skeleton (soft shimmer), generic headline immediately, chips enabled, CTA enabled (claim needs only the token). Alias swaps in without layout shift (alias line has fixed `minHeight` for 2 lines).
- **Slow (over 3 s) with no alias:** stay on the generic headline. No spinner.
- **Pass unavailable** (peek returns `unavailable`, identical for bad/expired/used): glyph disc replaced by `clock.badge.xmark` on gray; **This Spot Pass isn't active anymore.** / **It may have been used or timed out. Thanks for stopping to look, neighbor.** / quiet link **What's WePark?** (opens the install card, not a hard sell).
- **Offline at launch:** **Can't reach WePark right now.** / **Check your connection and try again.** / **Try again** (56 pt).
- **Self-scan** (seeker scans their own pass): **That's your own Spot Pass.** / **Show it to a neighbor who's leaving.**

### 3.9 Dynamic Type (clip), AX5

Everything in the `ScrollView` scales to AX5. Alias headline wraps to 4-5 lines; glyph disc shrinks to 72 and sits above. Chips become **a vertical stack of five full-width 56 pt rows**; CTA label wraps to 3 lines and the button grows; **CTA stays pinned** (`safeAreaInset(.bottom)`) with the consent line promoted above it. Reassurance lines stay in the scroll.

### 3.10 VoiceOver (clip)

| Element | Label | Notes |
|---|---|---|
| Glyph disc | "Bodega Cat, cat glyph" | decorative-with-name |
| Headline | "Bodega Cat is waiting for your spot." | `.isHeader` |
| Chips | "Leaving now" / "Leaving in 10 minutes" / "in 30 minutes" / "in 1 hour" / "Pick a time" | `.isSelected` trait on the chosen chip; group labeled "When are you leaving?" |
| CTA | "Tell Bodega Cat when I leave" | hint "A neighbor will be told when you pull out. That's all they will know." |
| Show me | "Show me this block" | hint "Uses your location once to look up street cleaning." |
| Result | one element: "This block. Street cleaning on this side: Tuesday, 8 to 9:30 AM. Next: Tuesday, December 2." | "Wrong side? Switch" as `.isButton` |
| I'm pulling out | "I'm pulling out" | hint "Tells Bodega Cat you are leaving. Only tap right before you go." |
| Not leaving after all | "Not leaving after all" | hint "Cancels your pass. Bodega Cat will not be told." |

---

## 4. Web fallback page (`handoff.html`, same moment, no clip)

**When it appears:** clip cannot run (iOS below the clip minimum, App Clips off, card dismissed, offline at card time, pre-release; spec §5.4) or a non-iPhone camera.

**Brand parity:** same indigo/ink gradient, same alias + glyph (peek via our own JS call, no third-party scripts), same sign-style headline, same buttons at the same sizes, same copy tone. Use `font-family: ui-rounded, -apple-system, system-ui` for headlines (SF Rounded where available); CSS `clamp()` type; `padding: env(safe-area-inset-*)`, `viewport-fit=cover`; `meta theme-color #0E0F24`; `prefers-reduced-motion` honors the confetti/float off-switch; the page honors `prefers-color-scheme` only by staying dark (dark-forced like the app).

```
+----------------------------------------------+
| WePark                                       |
|            ( cat glyph disc 96 )             |
|     Bodega Cat is waiting for your spot.     |  headline 32/800
|  Tell them you're leaving. They'll only      |
|  know you're pulling out, never who you are  |
|  or where you are.                           |
|                                              |
|  +----------------------------------------+  |
|  |   I'm pulling out now                  |  |  64px, white, ink text
|  +----------------------------------------+  |
|  +----------------------------------------+  |
|  |   Give me a few minutes                |  |  56px, outlined
|  +----------------------------------------+  |
|        Not now                               |  44px text button
|                                              |
|  Get the free app for a lock-screen          |
|  countdown and neighbor karma.  [Get WePark] |  hairline card, 56px button
|  Report this pass                            |  44px link
+----------------------------------------------+
```

**Flow (honest and short):**

1. **I'm pulling out now** claims with `leave_at = now`, then departs in the same action. Result state: **Sent. Bodega Cat knows you're pulling out. Drive safe.**
2. **Give me a few minutes** claims with `leave_at = now + 10 min` and changes the page to a hold state: **You're on. Keep this page open.** with a big **I'm pulling out** button and a **Not leaving after all** link (44px). Copy: **We can't remind you from a web page. Keep this tab handy.**
3. **Not now:** **No worries. Thanks for looking.**

**What the web page loses (state this on-page, quietly, in the Get-the-app card):** no lock-screen countdown, no reminder, no thank-you from the seeker, no karma carried to you, no "show me this block". There is no persistent identity, so **do not promise karma on the web.** Success copy: **Thanks, neighbor. Bodega Cat has been told.** with a quiet **Want credit next time? Get WePark.**

**Install prompt on web:** a Safari smart-banner `<meta name="apple-itunes-app" content="app-id=<id>, app-clip-bundle-id=com.kevinhoxha.wepark.Clip, app-argument=<pass URL>">` plus the in-page card above. Never a modal, never before the action.

Confetti on success: CSS-only, 24 particles, 1.6 s, indigo/lavender/white/sky; off under `prefers-reduced-motion` (static sparkle icon instead).

Accessibility (web): real `<button>` elements, `aria-live="polite"` on the status line, visible focus ring in lavender, 4.5:1 contrast verified for lavender-on-ink, text scales with browser font size to 200%.

---

## 5. Lock-screen Live Activity

The centerpiece. Constraints: lock-screen presentation max about 160 pt tall, no network/location, Dynamic Type applies, Reduce Motion applies to its own animations. **Background:** `activityBackgroundTint(passInk)` (dark, always white text, independent of wallpaper) with `activitySystemActionForegroundColor(.white)`. Linear progress via `ProgressView(timerInterval:countsDown:)` (F3).

### 5.1 Driver, full app, lock screen: counting down

```
+--------------------------------------------------+  160pt max
|  (cat)  Bodega Cat is waiting         Not leaving |  row 44
|         9:42                                      |   timer .title bold rounded mono (36)
|  [=============================------------]     |  6pt bar
|  +----------------------------------------------+ |
|  |                 Leaving now                  | |  56pt, passIndigo fill, white .title3 bold
|  +----------------------------------------------+ |
+--------------------------------------------------+
```
Vertical: 12 pad + 48 (glyph/caption/timer) + 6 + 6 + 6 + 56 + 12 = **146 pt**.

| Part | Spec |
|---|---|
| Glyph | 44 pt disc, tint gradient, white glyph |
| Caption | `.footnote`, white 80%: **Bodega Cat is waiting** |
| Timer | `Text(timerInterval:)`, `.monospacedDigit()`, rounded bold, white |
| "Not leaving" | text button, `.subheadline`, lavender, **44 pt tall, 96 pt wide hit area**, trailing, with 12 pt of separation from the primary button (separate row, so a thumb aiming for "Leaving now" cannot hit it) |
| **Leaving now** | `Button(intent: LeavingNowIntent(passId))`, full width, 56 pt, `passIndigo` fill, white label, `.title3` bold |

Tapping Leaving now triggers the intent; the activity updates to the **Sent** state (5.1c). On a locked phone, the OS may require unlock first (spec §7.2 device test); the design is identical either way.

### 5.1b Driver, time to go (at `leave_at`, alert configuration so it wakes)

```
+--------------------------------------------------+
|  Time to go?                          Not leaving |  row 44, .title3 bold rounded / text btn
|  Bodega Cat is waiting.                           |  .footnote
|  +--------------------------+ +------------------+|
|  |       Leaving now        | |   5 more min     ||  56pt: 60% / 40% widths, indigo fill / material fill
|  +--------------------------+ +------------------+|
+--------------------------------------------------+
```
Height: 12 + 44 + 18 + 8 + 56 + 12 = **150 pt**. Alert: system sound is the default; no custom sound.

### 5.1c Driver, sent / celebration / thanks / ended

| State | Layout | Exact copy |
|---|---|---|
| **Sent** (2 s) | Check-seal glyph left, 2 lines | **Sent. Bodega Cat knows you're pulling out.** / **Drive safe.** |
| **Celebration / pending** (until thanks or 30 min) | Glyph + stamp | **You passed a spot.** / chip **+5 karma when they get it** (dashed outline) |
| **Thanks** | Glyph + settled chip | **Thanks, neighbor!** / **Bodega Cat got your spot.** chip **+5 karma** (solid), ends 10 min later |
| **Cancelled** | one line, dismisses immediately | **Pass cancelled.** |
| **Ended / expired** | one line | **This pass has ended. Thanks for being ready, neighbor.** |
| **Auto-detect armed** | The caption row gains a trailing `location.fill` 12 pt icon + text | **Bodega Cat · auto heads-up on** (full app only, flag-gated, section 5.4) |

### 5.2 Driver, **clip** variant (no interactive intent, F-spec §4)

Same layout. Buttons are **`Link`** views styled as buttons, not intents. Labels carry the open affordance:

```
|  +----------------------------------------------+ |
|  |            Leaving now   >                   | |  56pt, passIndigo fill; chevron signals "opens WePark"
|  +----------------------------------------------+ |
```
- The whole activity also has `widgetURL(...)` to the pulling-out screen (3.6), so a tap anywhere is a fast path.
- **Not leaving** is a Link to the pulling-out screen with the confirm sheet pre-opened (Opening alone must **not** cancel, because opening is ambiguous).
- **Time to go** variant: **Leaving now >** and **5 more min >** both deep-link, with the clip performing the action on open (spec §7.3 pattern) and a toast **Done. +5 minutes.**
- Honest line in the clip's own post-claim screen: *"Tap it when you pull out."* (never "one tap"). The fastest honest path is lock screen, tap, tap.
- The install card later sells "Next time, one tap from your lock screen" (section 8.1).

### 5.3 Dynamic Island

| Region | Content | Notes |
|---|---|---|
| **Compact leading** | 28 pt glyph disc (alias tint) | decorative |
| **Compact trailing** | `Text(timerInterval:)`, `.caption2` mono rounded, `minimumScaleFactor(0.6)`, max width 52 | Above 1 h it is `h:mm:ss` and scales to fit (F15) |
| **Minimal** | 28 pt glyph disc only | no text |
| **Expanded leading** | Glyph disc 44 + **Bodega Cat** `.headline` | |
| **Expanded trailing** | Timer `.title2` rounded mono | |
| **Expanded center** | caption **is waiting for your spot** `.footnote` | |
| **Expanded bottom** | [**Leaving now**] 52 pt indigo, full width; below it a 44 pt `Not leaving` text button | clip: Links, with chevron |
| **Time to go (expanded)** | center **Time to go?**; bottom [Leaving now] [5 more min] | |
| **Sent/Thanks (expanded)** | check-seal + one line | copy as 5.1c |

Dynamic Island keylines: `keylineTint(passIndigo)`. Never green.

### 5.4 Auto-detect armed-state indicator (designed, not the hero)

Ships last behind `spotHandoffAutoDetectEnabled`. The OS shows the blue status-bar pill; we add three visible, non-alarming signals, never a banner that competes with the Leaving now button:

1. **Live Activity caption** (5.1c): `location.fill` icon + "auto heads-up on".
2. **In-app driver screen row** (full app), a 64 pt material row: **Auto heads-up is on** / **We'll tell Bodega Cat when you drive off. This stops after 60 minutes or when you cancel.** / trailing **Turn off** (44 pt min).
3. **Window ended:** one-line toast **Auto heads-up is off.** (no sound, no haptic).

**Enable screen** (one-time, second explicit opt-in, spec §9 item 1), a full-height sheet, white-on-ink, 64 pt primary:

| Element | Copy |
|---|---|
| Title | **Let WePark tell your neighbor for you** |
| Bullet 1 | **Only while a Spot Pass is active.** Up to 60 minutes, then it stops. |
| Bullet 2 | **Your location stays on your phone.** WePark only sends "leaving", never where. |
| Bullet 3 | **You'll see a blue pill at the top** while it's on. Cancel anytime. |
| Primary | **Turn on auto heads-up** |
| Secondary | **Not now** |
| No saved car | **Save your car's spot first** (disabled primary, helper "Auto heads-up needs to know where your car is parked.") |

The auto-detect UI must never imply it replaces the button: the Leaving now button stays at full size at all times.

### 5.5 Seeker variant (**Phase 2; recommend first fast-follow**, F11)

Seeker goes to a navigation app once armed; a lock-screen status is genuinely useful. Requires server-side ActivityKit pushes every 5 minutes to keep the coarse band current (backend scope).

```
+--------------------------------------------------+
|  (cat)  Your Spot Pass is live                    |  open: caption + timer "Good for 14:20"
|         14:20                                     |
|  [=========================------]                |
|  [          Stop waiting          ]               |  56pt, material fill (intent button)
+--------------------------------------------------+

+--------------------------------------------------+
|  (cat)  A neighbor's leaving                      |  armed: static string, push-updated
|         in about 30 min                           |  .title3 bold
|         It's a courtesy, not a promise.           |  .footnote
+--------------------------------------------------+

+--------------------------------------------------+  departed: alert update wakes screen
|  Spot opening up.                                 |
|  Your neighbor is pulling out now.                |
|  [ Got it, thanks! ]   [ Didn't work out ]        |  56pt: indigo fill / material fill
+--------------------------------------------------+
```
Dynamic Island: compact leading glyph; compact trailing **~30m** (static, push-updated); minimal glyph; expanded the same three states. `Got it, thanks!` is an intent button (`confirm_handoff_outcome`) and **never** used as a nudge to look at the phone while driving: first-use copy tells seekers to pull over before interacting.

### 5.6 Dynamic Type, Reduce Motion, VoiceOver (Live Activity)

- **Dynamic Type:** lock-screen presentation caps at `.accessibility1` (160 pt is a hard OS limit). At AX sizes: drop the glyph disc, drop the caption line, keep **timer + Leaving now (full width, grows to 64) + Not leaving**. The timer is the largest text.
- **Reduce Motion:** the only animated element is the progress bar, which is a system timer view and not decorative; the Sent-state seal uses a crossfade.
- **VoiceOver:** timer element label "Time until you leave" (value reads the system timer); Leaving now "Leaving now" hint "Tells Bodega Cat you are pulling out. They will see only that you are leaving."; Not leaving "Not leaving" hint "Cancels your pass. Bodega Cat will not be told."; 5 more min "Five more minutes".
- **Live Activities disabled** (`areActivitiesEnabled == false`): fallback copy shown in the clip/app (section 3.4) and the reminder notification (section 6) carries the same transparency.

---

## 6. Reminder notification (driver)

Local notification at `leave_at`, and a "last call" at `leave_at + 10 min`. Category `SPOT_PASS_LEAVING`, thread id `spotpass-<passId>`, `interruptionLevel = .active`, default sound, no badge. **Never mentions location, an address, or the seeker's identity beyond the alias the driver already saw.**

| Notification | Title | Body |
|---|---|---|
| At `leave_at` | **Time to go?** | **Bodega Cat is waiting for your spot.** |
| Last call (+10 min) | **Still leaving?** | **Bodega Cat's pass wraps up in 5 minutes.** |
| Name-on variant | same | **Maya is waiting for your spot.** |
| Alias-less if lock-screen preview hidden | **Time to go?** | **A neighbor is waiting for your spot.** (set `hiddenPreviewsBodyPlaceholder`) |

Actions (in order; foreground flags per spec §7.3, clip: opens and performs immediately with a toast):

| Action | Label | Icon (`UNNotificationActionIcon`) | Options |
|---|---|---|---|
| Send | **Leaving now** | `car.fill` | `.authenticationRequired` false; full app: background; clip: opens |
| Extend | **5 more min** | `plus.circle` | background (disappears after 3 uses) |
| Cancel | **Not leaving** | `xmark.circle` | **not** `.destructive` (destructive renders red; red is curb meaning) |

Tapping the body opens the **pulling-out screen** (3.6). Quiet by design: no urgency language, no countdown in the text ("hurry" and "last chance" are banned, section 10).

Seeker notifications:

| Event | Title | Body |
|---|---|---|
| `armed` | **Someone's on it** | **A neighbor will be leaving in about 30 min.** |
| `departed` | **Spot opening up** | **A neighbor is pulling out now.** |

(Spec §7.1 copy "Spot Pass: your neighbor is pulling out now." kept in substance; the title carries the brand name in the system's app label, so repeating it wastes the line.)

Thank-you to the driver is in section 7.4.

---

## 7. Celebration and thank-you

### 7.1 Driver: "You passed a spot" (the payoff)

Triggered when `handoff-depart` succeeds. Full-screen in the clip and app (the Live Activity mirrors it, 5.1c).

```
+----------------------------------------------+
|                                              |
|       .  *    (confetti, 1.8s)   *  .        |
|                                              |
|            +----------------+                |
|            |   SPOT PASSED  |  ticket stamp, rotated -6deg, lands with a soft thud
|            |   (cat glyph)  |                |
|            +----------------+                |
|                                              |
|        You just passed a spot.               |  .largeTitle bold rounded
|   A neighbor is pulling in because of you.   |  .title3 lavender
|                                              |
|        [ ( heart ) +5 karma ]                |  pending chip: DASHED border, label dimmed
|     lands when they say thanks               |  .footnote
|                                              |
|  +----------------------------------------+  |  (install card appears after 1.5s, section 8.1, if clip)
|  |  Keep your karma ...                   |  |
|  +----------------------------------------+  |
|                 Done                         |  56pt text button
+----------------------------------------------+
```

| Element | Copy |
|---|---|
| Headline | **You just passed a spot.** |
| Sub | **A neighbor is pulling in because of you.** |
| Pending chip | **+5 karma** with a dashed `passLavender` outline and caption **lands when they say thanks** (never "you earned"; spec §6.1 forbids promising points that do not exist) |
| Full app: karma total | below the chip, `.footnote`: **12 karma · you've helped 3 neighbors** (only when karma > 0) |

**Motion:** stamp scales 1.25 to 1.0 with a spring (0.35 s), **one `.impact(.light)` on contact**; confetti 36 particles via `Canvas` for 1.8 s then stops (no looping). **Reduce Motion:** stamp fades in at 1.0, **no confetti**, static sparkle glyphs near the stamp. Confetti never covers the buttons and never fires twice.

### 7.2 Driver: thank-you moment ("Bodega Cat got your spot")

Arrives when the seeker taps **Got it, thanks!**.

- If the clip/app is open: the dashed chip **solidifies** (border 2 pt solid, fill `passIndigo`), `+5` counts up from 0 over 0.6 s, a ring ripple, `.notification(.success)`; headline swaps to **Thanks, neighbor!** with sub **Bodega Cat got your spot.**; glyph disc waves (a 2-frame tilt, 0.5 s).
- If not open: Live Activity final update (5.1c) and the push below. If the clip's 8 h window lapsed: the news waits for the next launch (spec §6.1 beat 4).

| Surface | Copy |
|---|---|
| Push title / body | **Thanks, neighbor!** / **Bodega Cat got your spot.** (name-on: **Maya got your spot.**) |
| Full-screen | **Thanks, neighbor!** / **Bodega Cat got your spot.** / chip **+5 karma** |

**Reduce Motion:** chip swaps style instantly, number appears final, no ripple or wave.

### 7.3 Seeker: "Got it, thanks!"

Shown when the seeker confirms. Full-screen, 1.6 s auto-advance to the outcome card (section 9.4 shows the buttons that lead here):

| Element | Copy |
|---|---|
| Headline | **Thanks, neighbor.** (mirrors the driver's) |
| Sub | **You just made someone's day easier too.** |
| Chip | **+3 karma** (1 for confirming, 2 for getting it; spec §10), counts up 0.6 s |
| Then | **Done** (56) · **Share my karma** (56, section 7.6) |
| Haptic | `.success` |

### 7.4 Seeker: "Didn't work out"

No confetti. **No worries. Thanks for trying.** / chip **+1 karma · for letting us know** / **Keep looking** (primary, creates a new pass) / **Done**. The driver gets nothing (spec §9 item 14).

### 7.5 Karma chip language (consistent everywhere)

| Variant | Visual | Used |
|---|---|---|
| Pending | dashed lavender border, 60% label | driver celebration, clip, Tier 1' welcome |
| Settled | solid indigo fill, white label | thank-you, Live Activity thanks, app karma |
| Bucket label | `heart.fill` + text | badge only (section 2.4) |
| Count | `heart.fill` + number | inside the app only |

### 7.6 "Share my karma" (token-free, F10)

A share image card, 1080 x 1350, `passInk` gradient, big **+3 karma** numeral, the alias glyph, line **I passed a spot today.** / **WePark · Pass the spot.** and the WePark wordmark. **Contains no QR code, no token, no URL with a token.** Uses `ImageRenderer`. Optional (not MVP-critical).

---

## 8. Install ask and the tailored first launch

### 8.1 The install ask (clip, peak emotion)

Never before the payoff (spec §6.1). Appears **1.5 s after the celebration lands** as a bottom card (not a modal), once per launch (F8).

```
+----------------------------------------------+
|  +----------------------------------------+  |  card: material over ink, radius 28, 20 pad
|  |  Keep your karma.                      |  |  .title2 bold
|  |  Get WePark to hold on to the good you |  |  .body
|  |  just did, and to hear when a spot     |  |
|  |  opens near you.                       |  |
|  |  Next time, leave from your lock       |  |  .subheadline lavender
|  |  screen in one tap.                    |  |
|  |  +----------------------------------+  |  |
|  |  |          Get WePark              |  |  |  64pt, white fill, ink label
|  |  +----------------------------------+  |  |
|  |            Not now                     |  |  44pt text
|  +----------------------------------------+  |
+----------------------------------------------+
```
**Mechanics:** our card carries the copy; **Get WePark** presents the system `SKOverlay` with `AppClipConfiguration` (the system banner's own copy cannot be changed, F5). **Not now** dismisses for the launch. If dismissed, never shown again in that launch; a thank-you push opens a new launch and may show it once more.

**Copy rules:** "Keep your karma" is the headline because the value is *theirs and fresh*. No "Download now", no discount language, no "limited". Secondary reason is the one that is true and specific: one-tap lock screen.

**AX:** the card grows and becomes a bottom sheet (`.large` detent at AX3+) with its own scroll; buttons stay 64 pt and pinned.

**VoiceOver:** card is a container, "Keep your karma. Get WePark to keep your karma and hear when a spot opens near you." Buttons "Get WePark" (hint "Opens the App Store") and "Not now".

### 8.2 Tier 1' ("Welcome, neighbor") replaces the 3-card deck on a clip-origin first launch (spec §6.3)

One `.fullScreenCover`, same mechanics as the story deck (no permission request, `.selection` haptic on appear, **no progress bar for a single card**), same container language as `first-run-onboarding-design.md` §1.5: `Color(.label)` fill primary button, `.ultraThinMaterial` Skip capsule, `minHeight: 56`+, text `ScrollView` above a fixed button at AX.

```
+----------------------------------------------+
|                                        Skip  |  .footnote semibold, material capsule, 44x44
|                                              |
|          +----------------------+            |
|          |  SPOT PASSED         |            |  illustration (code-drawn, ~45% height):
|          |   (cat glyph disc)   |            |  the same ticket stamp as the celebration,
|          +----------------------+            |  with a dashed curb-line "arc" behind it
|                                              |
|   Welcome, neighbor.                         |  .largeTitle bold rounded
|                                              |
|   You've already helped 1 person park.       |  .title3 secondary
|                                              |
|        [ (heart) +5 karma lands when         |  chip (pending/settled)
|          they say thanks ]                   |
|                                              |
|  +----------------------------------------+  |
|  |            Show me around              |  |  56+, Color(.label) fill, systemBackground label
|  +----------------------------------------+  |
+----------------------------------------------+
```
Differences from the deck: background is `passInk` gradient (warmer than the deck's neutral) so it reads as the *continuation of the clip*, not a new app; the button is the app's monochrome primary (white/label), consistent with onboarding.

**Copy matrix (exact):**

| Context (`clipHandoffContext`) | Headline | Body | Chip |
|---|---|---|---|
| `passesHelped == 1`, karma pending | **Welcome, neighbor.** | **You've already helped 1 person park.** | **+5 karma lands when they say thanks** (pending) |
| `passesHelped == 1`, settled | same | same | **+5 karma · yours to keep** (settled) |
| `passesHelped >= 2` | **Welcome, neighbor.** | **You've already helped N people park.** | **N x 5 karma** settled / pending variant if any pending |
| `passesHelped == 0` (armed but never departed) | **Welcome, neighbor.** | **You were ready to pass a spot. That's what this is all about.** | none |
| Primary | **Show me around** | | |
| Secondary | **Skip** | | |

On **Show me around** or **Skip**: set `hasSeenOnboardingStory = true`, `hasSeenClipWelcome = true`, continue to Tier 2 (unchanged), then Tier 3 coach (unchanged), per spec §6.3. Replay ("How WePark works") keeps playing the standard 3-card deck.

**Motion:** the stamp settles once (0.35 s spring); chip dashed to solid draw-on if settled (0.5 s) else static. **Reduce Motion:** all static.

**VoiceOver:** the cover is announced "Welcome, neighbor. You've already helped 1 person park. 5 karma pending until they say thanks." Chip is `.isStaticText`; buttons "Show me around" and "Skip".

**Dynamic Type AX5:** illustration shrinks to its 160 pt floor; headline/body scroll above the fixed button.

### 8.3 Notifications and permissions in this funnel (restating the design rule)

No prompt on the welcome. **Notification rationale** (Spot Pass's own `SpotPassNotificationRationaleView`, shown once) appears **at the first action that needs it**: creating a Spot Pass as a seeker (section 9.2) or enabling auto heads-up (5.4). Rationale copy for Spot Pass: **"Get a heads-up. We'll let you know the moment your neighbor is pulling out, even if your screen is locked."** / **Allow notifications** / **Not now** (then the badge keeps working with the in-app state and a banner: **Notifications are off. Keep this screen open to see when a neighbor scans.** with a Settings link).

---

## 9. Seeker flow in the full app

### 9.1 Entry points

- **MVP:** a new **More sheet** row, placed **row 2** (below Report, above "What the colors mean"; `goal-first-ambient-design.md` A3.4): **Spot Pass** / **Ask a neighbor for their spot** / icon `ticket.fill` on the standard blue 44 pt square. (Row order is a design call: Spot Pass is a hero feature but must not displace the established Report row.) Two taps from launch.
- **Cruise-context option for Kevin (not default):** after 6 minutes of Cruise on the cheap loop without a green hit, show a **one-time, dismissible** pill **Circling? Ask a neighbor for their spot.** (56 pt) per drive. Honors §0.1 "no nag" only because it is once per drive and the first dismissal turns it off permanently. Hold until Kevin approves; flagged as a product call.
- Not on the rail (rail never exceeds three circles). Not on the dock.

### 9.2 Creating a pass (first-time explainer, then a one-tap repeat)

First run only, a `.medium` sheet:

```
+----------------------------------------------+
| ----- (drag)                           Close |
|  Pass the spot.                              |  .largeTitle bold rounded
|                                              |
|  (1) Show your pass to someone walking to    |  rows: 44pt blue-indigo circle numeral + .body
|      their car.                              |
|  (2) They scan it with their camera. No app  |
|      needed.                                 |
|  (3) You get a heads-up the moment they pull out.|  "heads-up", never "ping" (§10.1 banned-word rule)
|                                              |
|  Hold it up to your window. Please set it up |  .footnote secondary
|  while parked.                               |
|                                              |
|  Show my first name                [ off ]   |  Toggle row, 64pt
|  Off: neighbors see "Bodega Cat".            |  helper, .footnote
|  On: they see "Maya". Never your last name.  |
|                                              |
|  +----------------------------------------+  |
|  |       Create my Spot Pass              |  |  64pt, blue fill? see note
|  +----------------------------------------+  |
+----------------------------------------------+
```
Primary uses the app's selection blue (`.borderedProminent` `.tint(.blue)`, consistent with the "Pick a parking goal" button in the same app); the dark indigo takes over on the badge itself. After the first time the sheet is skipped and the badge opens directly (the identity toggle moves to Settings > Spot Pass and is shown as a one-line row on the badge's first appearance).

**Both identity states**

| | Toggle off (default) | Toggle on |
|---|---|---|
| Badge alias line | **Bodega Cat** (+ cat glyph) | **Maya** (+ the pass's glyph) |
| Driver's clip headline | **Bodega Cat is waiting for your spot.** | **Maya is waiting for your spot.** |
| Driver's thank-you | **Bodega Cat got your spot.** | **Maya got your spot.** |
| Helper text | **Off: neighbors see "Bodega Cat".** | **On: they see "Maya". Never your last name.** |

**No first name on file (F12):** toggle disabled, helper **Add a first name in Settings to turn this on.** The name is purged with the row (24 h). If a first name fails the banned-word check (section 10.3) the badge silently falls back to the alias.

Notification rationale appears here if status is `.notDetermined` (8.3), then the badge.

### 9.3 Waiting states and the coarse bands (F4)

The seeker never sees a clock time or an mm:ss to the driver's departure. After arming the badge shows (updating at most once per minute locally, or per the 5-minute ActivityKit push in Phase 2):

| Time to `leave_at` | Sign line 1 / line 2 | Never shown |
|---|---|---|
| more than 55 min | **A neighbor's on it.** / **Leaving in about an hour.** | exact minutes |
| 45-55 min | **...** / **Leaving in about 50 min.** | |
| rounds to nearest 5 min until 10 min | **...** / **Leaving in about 30 min.** | |
| 10 to 5 min | **...** / **Leaving in about 10 min.** | |
| 5 min or less, before `leave_at` | **A neighbor's on it.** / **Leaving any minute now.** | |
| after `leave_at`, within grace | **A neighbor's on it.** / **Should be heading out soon.** | "late", "delayed" (no pressure signal about the driver) |
| after `leave_at + 15 min` | **Pass ended.** (no reason) | |

Always under it: **It's a courtesy, not a promise.** (`.footnote`). Never "is walking to the car", never a reason. Driver cancel is silent: it appears as "Pass ended."

While waiting in the armed state the bottom action is still **Stop waiting** (56 pt). Seeker taps it: confirmation not needed (cheap, reversible by making another pass); the pass cancels and the driver is not told.

### 9.4 "Spot opening up" and the outcome

The `departed` push and the in-app state show:

```
+----------------------------------------------+
|              [ ripple rings ]                |
|              (cat disc 160)                  |
|                                              |
|        Spot opening up.                      |  .largeTitle bold rounded
|   Your neighbor is pulling out now.          |  .title3
|                                              |
|  It's a courtesy, not a promise. Stay        |  .footnote
|  alert when you head over.                   |
|                                              |
|  +----------------------------------------+  |
|  |           Got it, thanks!              |  |  68pt, indigo fill (blue in app chrome? indigo, this is the badge world)
|  +----------------------------------------+  |
|  +----------------------------------------+  |
|  |           Didn't work out              |  |  56pt, material fill, neutral
|  +----------------------------------------+  |
+----------------------------------------------+
```
- Both buttons are big and neutral; **"Didn't work out" is never red or gray-out styled as a failure**.
- Auto-ends after 30 minutes if no choice is made: **Pass ended.**
- **Got it, thanks!** opens 7.3; **Didn't work out** opens 7.4.
- Safety line is intentionally plain: **Stay alert when you head over.** No "hurry", no "grab it".

### 9.5 Edge states

| State | Copy / treatment |
|---|---|
| Notifications denied | banner **Notifications are off. Keep this screen open to see when a neighbor scans.** + **Open Settings** (56) |
| Seeker parks | Pass ends silently; **You parked. Spot Pass is off.** toast |
| Offline when creating | **Can't make a pass without a connection.** / **Try again** |
| Already active pass | opens it (one active pass per seeker) |
| Self-scan | clip/app: **That's your own Spot Pass.** (3.8) |
| Reported/suspended | **This Spot Pass has been paused.** neutral, no detail |

### 9.6 Dynamic Type, Reduce Motion, VoiceOver (seeker)

Covered per-surface above. Summary: badge scroll rules (2.7); explainer sheet becomes `.large` and scrolls at AX3+; the two outcome buttons stack and grow; ripple/confetti off under Reduce Motion; VoiceOver announcements on state changes (2.9). Every control has an `accessibilityLabel`; the toggle uses system `Toggle` semantics with the helper text as `accessibilityHint`.

---

## 10. Tone and voice; the alias and glyph system

### 10.1 Voice: a good neighbor on a stoop, not a brand

| Principle | In practice |
|---|---|
| **Warm, brief, concrete.** | Short sentences, say what will happen. "We'll tell Bodega Cat when you leave." |
| **NYC-warm, not NYC-caricature.** | Stoops, bodegas, "neighbor". Never dialect spelling, never "fuhgeddaboudit", never a stereotype. |
| **Thanks over points.** | Karma is a receipt for a good deed: "lands when they say thanks". No "earn", "unlock", "rewards", "level up", dollar signs. |
| **Humble about promises.** | "It's a courtesy, not a promise." Spots can still go. |
| **Never cutesy about safety.** | Safety, privacy and driving lines are plain and calm: "Please don't use your phone while driving." "That's all they'll know." No emoji, no puns, no exclamation marks in safety copy. |
| **One exclamation point per screen, max, only on thanks.** | "Thanks, neighbor!" / "Got it, thanks!" |
| **No pressure.** | Never "hurry", "last chance", "don't miss", "running out", "grab", "steal", "score". Reminders are nudges, not guilt. |
| **Never mention location, address, or where a car is.** | Copy says "this block", "this side". |
| **AC-31 vocabulary.** | No "avoid/ticket/fine/dodge/evade". "Move it" is the app's own honest phrase. |

**Words we use:** pass, spot, neighbor, thanks, leaving, pulling out, "on my way". **Words we avoid:** ping (internal jargon, banned in user-facing copy: say "heads-up"; user-facing "tell"/"let them know"), karma *points*, "claim", "token", "scan to win", "free spot" (green/free ambiguity per goal-first §0).

**Do / Don't pairs**

| Do | Don't |
|---|---|
| "Tell Bodega Cat when I leave" | "Ping the seeker" |
| "You just passed a spot." | "You earned 5 points!" |
| "It's a courtesy, not a promise." | "Guaranteed spot!" |
| "Leaving soon? Scan to pass me your spot." | "FREE PARKING - SCAN NOW" |
| "This Spot Pass isn't active anymore." | "Error: invalid token" |
| "Please don't use your phone while driving." | "Drive safe!! 😊" |

### 10.2 Alias + glyph system (sketch for @backend-data and @ios-engineer)

**Alias = `<Modifier> <Animal>`.** Generated **server-side in `create_handoff`**, stored on the pass row, drawn fresh per pass from a CSPRNG (not a hash of the user id) so aliases do not link passes to a person (spec §3).

Never repeat the previous alias for the same seeker.

**Modifiers (14, NYC flavor, no place names):** Bodega, Stoop, Brownstone, Rooftop, Crosstown, Corner, Express, Local, Midnight, Sidewalk, Bagel, Pretzel, Slice, Crosswalk.

**Animals (8) with their glyph (SF Symbol, available on the clip with no asset cost):**

| Animal | SF Symbol |
|---|---|
| Cat | `cat.fill` |
| Pup | `dog.fill` |
| Pigeon | `bird.fill` |
| Sparrow | `bird.fill` (same glyph, different tint) |
| Hare | `hare.fill` |
| Turtle | `tortoise.fill` |
| Ladybug | `ladybug.fill` |
| Gecko | `lizard.fill` |

14 x 8 = **112 aliases**. Collisions are fine (they are per-pass and never shown to the same neighbor pair twice in a day). Longest alias "Brownstone Ladybug" (18 chars) wraps to two lines at larger sizes; the layouts above reserve two lines.

**Tint:** four tonal gradients (indigo, blue, purple, slate-blue) chosen by `hash(pass id) mod 4`, so the disc looks different on every pass even for the same animal. All with a white glyph at least 4.5:1. **No green, teal, orange, red, yellow.**

**Display strings** are built from the stored `alias` + `glyph` + `tint_index` on the row; the client never reconstructs them from anything else.

### 10.3 Banned words and lint

Enforced three ways: a **CI test that enumerates the full 112-combination cross product** (and the first-name opt-in path), a **substring check** on each concatenation (catches accidental words), and a **manual read-through of the cross product by a human before launch**.

| Banned category | Examples (not exhaustive) |
|---|---|
| Real places | boroughs, neighborhoods, streets, landmarks (Brooklyn, Queens, Bronx, Harlem, SoHo, Williamsburg, "Broadway"...). **Aliases must never hint at location** (privacy). Also "Uptown/Downtown/Midtown". |
| People and identity | any human first name or surname, gender, age, ethnicity, religion, nationality |
| Brands and marks | Uber, Lyft, Tesla, Citi, Dunkin, etc. |
| Vehicles | makes, models, colors, body types ("sedan", "SUV", "taxi", "cab", "plate") |
| Authority and impersonation | cop, police, warden, agent, inspector, "meter maid", "ticket" |
| Urgency/scarcity | hurry, rush, quick, last, fast, snatch, steal, grab |
| Sexual, violent, drug, slur, profanity | including leetspeak and hidden substrings across the word boundary |

The **opt-in first name** passes through the same filter (and a profanity/impersonation check); on any failure the badge silently falls back to the alias and does not tell the seeker why.

### 10.4 Karma voice

Karma is "the receipt for a good deed". Label it **karma** (not points, not rewards). It is never redeemable and never framed as money (concept doc §6). Settled copy: "+5 karma". Pending copy: "+5 karma lands when they say thanks". Bucket labels on the badge ("Helped a few", "Helped 10+"). In-app summary: **You've helped 3 neighbors park.** (matches the concept doc phrasing "You've helped 41 neighbors park").

---

## 11. Engineer handoff checklist

**New SwiftUI views (names suggested):** `SpotPassBadgeView` (+ `SpotPassQRView`, `KarmaChip`, `AliasGlyphDisc`), `SpotPassCompactCard`, `SpotPassOutcomeView`, `SpotPassExplainerSheet`, `SpotPassCelebrationView`, shared `Shared/SpotPass/` for the clip (first screen, chips, pulling-out, block card, install card), `WelcomeNeighborView` (Tier 1'), `SpotPassLiveActivity` (driver + clip), `SpotPassNotificationCategory`.

**Reuse:** `ParkingColors` only in the clip's block card; `NotificationRationaleView`; the onboarding Skip capsule and monochrome primary idiom; More sheet row anatomy (64 pt rows, 44 pt icon squares).

**Tokens to add:** `passInk`, `passInkRaised`, `passLavender`, `qrInk`, `qrEye` (new), `Color.indigo` (system).

**Acceptance checks added by this design (for @qa-verifier):**

1. Palette audit: grep and visual check, no green/orange/red/yellow/teal/pink in any Spot Pass surface except the clip's "cleaning in effect right now" pill.
2. QR contract (1.5): v4-M, 33 modules, 8 pt module at integer pixels, 4-module white quiet zone untouched, center mark exactly 5 x 5, no animation/blur/material over the plate, test table passed with branded-vs-plain delta at most 3 points.
3. Badge is first element in scroll at AX5; Stop waiting pinned; sign headline capped; VoiceOver labels match section 2.9.
4. Coarse bands only on the seeker side after arming; no clock time or mm:ss to departure anywhere in the seeker UI, notification, or Live Activity.
5. The shared share-image never contains a token or QR.
6. Clip install card uses `SKOverlay`, shown once per launch, after the celebration only.
7. Tier 1' copy matrix, keys, and flow equal section 8.2 / spec §6.3; deck unchanged for organic installs.
8. Notification actions: no destructive style on "Not leaving".
9. Reduce Motion pass on every motion row (no confetti, no float, no ripple, crossfades only).
10. Brightness restores on every terminal state and on backgrounding; Night mode persisted.
11. Live Activity at AX1 fits 160 pt with timer + Leaving now + Not leaving.
12. 44 pt minimum on every text button; 56 pt+ on chips and secondary buttons; hero CTAs at least 60-68 pt.

**Needs a device test before copy is final:** clip LA `Link` behavior and `widgetURL`; whether `Button(intent:)` happens to work in a clip LA; whether the notification action performs-on-open in the clip; whether the fragment `#t=` survives invocation; side-window film decode rates.

---

## 12. Out of scope (future; captured, not requested)

- **AirDrop / Messages "send my pass" to a nearby neighbor** (also the accessibility alternative to aiming a QR for VoiceOver users); needs a fresh safety review.
- **Neighborhood "Stoop" leaderboards / "Mayor of the block" badges** (spec Phase 3), built from karma buckets, not exact counts.
- **Seasonal alias packs** (Snow Day Pigeon, Heatwave Hare) that rotate with the weather. Pure delight, small.
- **A Spot Pass widget** for the home screen (compact card with Show QR).
- **Lock-screen widget for the seeker's pass** so the QR is one tap away from the lock screen when the phone is mounted.
- **Spanish/Chinese localization of the card and clip** (spec Phase 2): copy here is short and concrete specifically so it translates.
- **Cruise contextual suggestion** (section 9.1) after Kevin's call.
- **Seeker-side Live Activity** (section 5.5) as the first fast-follow.

---

## What's working in the spec

- Putting the QR owner as the seeker and making the *scan* the consent is the right shape; the safety table is genuinely thorough and the design never needs to bend it.
- Naming the card as unpersonalizable and moving personalization into the clip's first screen is exactly the right split.
- "Earned ask" thinking in section 6 (value before any permission) maps cleanly to a calm, one-decision screen.
- Karma as pending-then-settled (spec §6.1 beat 4) is the best emotional device in the document; the design leans on it everywhere.
- The two-tap clip fallback is acknowledged honestly instead of faked; the design makes it first-class.

File: `/Users/kevinhoxha/repos/parkmap/docs/design/spot-pass-design.md`
