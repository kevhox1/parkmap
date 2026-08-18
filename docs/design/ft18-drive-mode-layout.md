# FT-18 — Drive Mode control layout redesign

**Reviewer:** Designer (read-only on source).
**Trigger:** Kevin, build-16-candidate screenshot, 2026-08-13 — "the spacing on all the buttons in
drive mode looks really bad… Let's consider Apple Maps as the base product. Maybe all buttons are
on the bottom? I want it to be clean." (`docs/field-testing-log.md`, FT-18.)
**Scope:** Drive Mode chrome only — the floating controls layered over the live map during
`driveModeActive == true` (both `.destination` and `.cruise` styles). Not in scope: map rendering,
the parking-severity color palette (chip colors, ASP banner colors — those are load-bearing data
encoding and were already tuned for contrast in the prior pass, see below), or browse-mode UI.
**Method:** Static code review of `ios/WePark/WePark/ContentView.swift`, `Views/DriveModeBottomCard.swift`,
`Views/ASPBanner.swift`, `Views/ParkUntilSheet.swift`, plus the prior design doc
`docs/design/drive-mode-ui-review-2026-07-09.md` and its landed follow-ups (visible in-code as
"TF2-18 P1-1", "P1-3", "P2-1", "P2-2", "P2-5" comments). No device access — line/behavior citations
are read from source, not inferred from the screenshot alone.

---

## Summary

This is a second pass at the same surface. The **2026-07-09 TF2-18 review already landed** —
chip contrast is fixed (solid-fill, ~9.9:1), the four action buttons share one capsule anatomy,
the two toolbar clusters share one vertical offset (`100pt`), and the Recenter pill has
coordinated (if hand-computed) clearance from the bottom card. Those were the right fixes for what
they targeted: **internal consistency within each cluster.** Kevin's new complaint is not about
that — it's that **there are still two clusters**, plus a permanently-visible browse-mode toolbar
that has no business being on screen while driving. That's a structural problem, not a spacing
token problem, and it's why the screenshot still reads as "clunky" even though every individual
button now technically follows the same rules.

Reading the actual composition in `ContentView.swift` surfaced three concrete bugs beyond what the
screenshot shows: **the gear button and the "End Drive" pill render at the identical top-left
coordinate** (both `padding(.top: 100, leading: 12)`, gear underneath) and likely visually collide;
**the mute toggle renders twice simultaneously in Cruise Mode** (once in the top row, once — always
— inside `DriveModeBottomCard`, same `drivingVoice.isMuted` state, two different shapes); and the
top-right toolbar's "Find me" / "Find my car" buttons remain live during Drive Mode but call
`recenterMap(on:)`, a flat 400m-span browse recenter with no pitch restore — a different, wrong
camera pipeline from `recenterDriveMode()` — so tapping them mid-drive produces a broken, un-tilted
camera state.

Kevin's instinct — bottom-anchored, one control language, Apple Maps as reference — is right and
is what I recommend below, with one explicit, flagged deviation: the destructive "End Drive" /
"End Cruise" control should **not** sit in the same reachable cluster as "Park Here" and "Report."
Apple Maps doesn't do that either — its own "End" control lives in its own corner, away from the
primary action row, specifically because ending a live session is a different risk class than the
frequent actions next to it. Full reasoning and two proposals below.

---

## Current-state critique

### What's already fixed (don't re-litigate)
- Chip contrast: solid-fill severity backgrounds, ~4.9–12:1 (`DriveModeBottomCard.swift:193–245`).
- Button anatomy: End Drive / Report / Park Here all share capsule + `Label(icon, text)` +
  explicit `minHeight: 44` (`ContentView.swift:1437–1556`, "TF2-18 P2-1" comments).
- Top-cluster vertical alignment: both toolbars now share `padding(.top, 100)`
  (`paddingForBannerState`, `ContentView.swift:2659–2667`).
- ASP banner: correctly implemented as a `.safeAreaInset(edge: .top)` push, not an overlay — it
  reserves space rather than covering map content (`ContentView.swift:1092`). This is the right
  pattern and nothing here proposes changing it.

### What's still wrong

**F1 — Two competing anchors persist, now with a dead zone between them.**
`ContentView.swift:1094–1096` pins `recenterButtonStack` (Find me / Find my car / Park Until /
resting Drive icon — 4 buttons) top-**trailing**. `ContentView.swift:1430–1586`
(`driveModeOverlayLayer`) renders End Drive / Report / Park Here top-**leading**, and the row ends
in a trailing `Spacer()` (`:1558`) that pushes all three buttons hard against the left edge,
leaving the entire right two-thirds of that row empty **except** for the unrelated toolbar
floating in the top-right corner. That empty gap plus two visually distinct button languages
sharing the same horizontal band is very plausibly what reads as "spacing looks bad" — it's not
that the padding numbers are wrong, it's that the row has no compositional logic: it isn't
centered, isn't balanced, and doesn't acknowledge the other cluster exists.

**F2 — Gear button and "End Drive" pill occupy the identical coordinate.**
`gearButtonOverlay` (`ContentView.swift:1146–1181`) uses `.padding(.top, 100).padding(.leading, 12)`
with no gating on `driveModeActive` (only the adjacent "?" guide button hides, via
`parkingGuideButtonVisible`, `:1165`). `driveModeOverlayLayer`'s End Drive button uses the *same*
`.padding(.top, 100)` on its container plus its own `.padding(.leading, 12)` (`:1442, 1458, 1560`).
`driveModeOverlayLayer` renders after (on top of) `gearButtonOverlay` in the ZStack (`:1098–1099`),
so the gear icon sits directly under/behind the End Drive capsule at the exact same corner. At
minimum this is visual clutter the driver has to parse; at worst the gear button's tap target
extends into space the End pill doesn't visually cover, producing a surprise tap. Not confirmed on
device, but it follows directly from the layout code and is worth a real-device check regardless
of which proposal below ships.

**F3 — The mute toggle renders twice in Cruise Mode.**
`driveModeOverlayLayer` shows a standalone mute button `if driveModeStyle == .cruise`
(`ContentView.swift:1463–1475`). `DriveModeBottomCard.muteButton` (`DriveModeBottomCard.swift:277–297`)
renders **unconditionally**, in both the placeholder and context-present branches — i.e. in every
Drive Mode state, cruise or destination. Both are bound to the same `drivingVoice.isMuted`. In
Cruise Mode the driver sees two mute toggles on screen at once, different shapes, different
locations, same effect. This is a duplicate control, not a design-taste issue — it should simply
be deleted, not merely restyled.

**F4 — Two of the four top-right toolbar buttons are actively wrong during Drive Mode; one does nothing.**
- "Find me" (`recenterOnUser` → `recenterMap`, `ContentView.swift:1757–1769, 1788–1796`) writes a
  flat `MKCoordinateRegion` at a 400m span with no pitch and calls `coordinatorActions.setRegion?`
  directly — this is the **browse-mode** recenter path. Drive Mode's actual camera lives in
  `recenterDriveMode()` (`:1741–1750`), which resets altitude, resumes `followPaused = false`, and
  restores the 30° drive pitch. These are two different pipelines. Tapping "Find me" mid-drive
  either gets immediately overridden by the next GPS tick's `setDriveCamera` call (if follow was
  active — a visible flicker) or leaves the camera flat/untilted with `followPaused` unchanged (if
  follow was paused — a worse, stuck state, and the Recenter pill will still be showing next to it,
  offering the *correct* fix right beside the broken one).
- "Find my car" (`recenterOnCar`, `:1772–1776`) has the identical flat-recenter problem, plus it
  jumps the camera away from the live drive view to a possibly-distant fixed pin — disorienting
  while the car is moving, and there's no way back to drive-follow except the Recenter pill (whose
  presence the driver may not even notice caused it).
- The 4th button (combined Drive/Cruise entry) is replaced during Drive Mode with a non-interactive
  resting icon — the code comment says it outright: *"No action on tap"* (`:1363–1364`). A
  full 44×44 button that looks tappable and isn't is a real affordance violation
  ([HIG: controls should look actionable only when they are](https://developer.apple.com/design/human-interface-guidelines/buttons)).

None of F1–F4 are about spacing constants. They're compositional: too many independently-added
clusters, each internally fixed by the last pass, none reconciled against each other.

---

## States the layout must hold across

Enumerated from the actual `@State` flags in `ContentView.swift`, not just the screenshot:

| # | State | Driven by | Notes |
|---|---|---|---|
| S0 | Not in Drive Mode | `driveModeActive == false` | Baseline — recenter stack + gear + guide button all visible, as today. Unaffected by this proposal. |
| S1 | Cruise Mode, follow active, no context yet | `driveModeStyle == .cruise`, `followPaused == false`, `drivingContext == nil` | `DriveModeBottomCard` shows the "Looking for street…" placeholder (shorter card, `DriveModeBottomCard.swift:151–165`). |
| S2 | Cruise Mode, follow active, context resolved | `driveModeStyle == .cruise`, `followPaused == false` | Steady-state cruise: street + L/R chips, no approach strip (approach only applies to `.destination`, `handleFinalApproachUpdate` guard at `ContentView.swift:1672`). |
| S3 | Destination Mode, approaching | `driveModeStyle == .destination`, `finalApproachState == .approaching` | Approach strip shown inside the card (`showApproachStrip`, `DriveModeBottomCard.swift:82–96`), card is ~30pt taller. |
| S4 | Follow paused (pan or pinch, either style) | `followPaused == true` | Recenter control must appear, clear of the card, in every combination below. |
| S5 | Park Until filter carried over from browsing | `parkUntilMode == true`, entered *before* Drive Mode started (entry point is only reachable from the browse-mode toolbar) | `ParkUntilPill` stacks with the bottom card today (`bottomSafeAreaContent`, `ContentView.swift:1242–1272`) and must keep doing so — the filter can't be *entered* mid-drive in this proposal (toolbar hidden, see disposition table), but it must still be *visible and clearable* if it was already active. |
| S6 | Worst case: destination + approaching + paused + Park Until | all of the above at once | This is exactly the combination `recenterPillBottomPadding` (`ContentView.swift:2709–2714`) was built to survive. The proposal below should make this combination self-resolving via stacking, not hand-computed heights. |

---

## Proposal 1 — Bottom Dock (recommended)

**Thesis:** one anchor, one language, minimal top chrome. Everything that is a *frequent action or
live status* lives in a single bottom-anchored stack, directly above `DriveModeBottomCard`, using
one visual system: filled/tinted capsules for two-choice actions, small circular icon buttons for
one-off utility taps. The top of the screen is reduced to the ASP banner (unchanged, already
correct) plus **one** small, deliberately de-emphasized control for ending the session — the one
explicit exception to "everything on the bottom," explained below.

### Layout (steady state, S2 — Cruise Mode, no complications)

```
┌───────────────────────────────────────────┐
│           status bar / Dynamic Island      │
├─────────────────────────────────────────────┤
│           ASP in Effect Today                │  ← unchanged, safeAreaInset(top)
├─────────────────────────────────────────────┤
│                                        ⓧEnd │  ← small, top-trailing, isolated
│                                               │
│                                               │
│              MAP — nothing else              │
│              overlaying the road ahead        │
│                                               │
│                                               │
│   ┌─────────────┐        ┌─────────────────┐│
│   │  🚩 Report   │        │  📍 Park Here    ││  ← bottom action row, 16pt margins
│   └─────────────┘        └─────────────────┘│
│ ┌───────────────────────────────────────────┐│
│ │ W 34 ST                    🔊              ││  ← DriveModeBottomCard (unchanged slab)
│ │ LEFT    Free — check signs                 ││
│ │ RIGHT   No parking                         ││
│ └───────────────────────────────────────────┘│
│              home indicator                   │
└───────────────────────────────────────────────┘
```

Gear button: **hidden** entirely during Drive Mode (see disposition table — mirrors the existing
`parkingGuideButtonVisible` pattern, just extended to the gear icon). Top-right browse toolbar
(Find me / Find my car / Park Until entry / resting Drive icon): **hidden** entirely. Top of screen
is now just the banner + the End control — nothing floats over the part of the map showing the
road ahead, which was Kevin's exact complaint.

### S4 — follow paused (Recenter needed), any style

```
│                                               │
│              MAP                              │
│                                    ⊙          │  ← Recenter: small circular icon
│                                    (44×44)     │     button, own row, trailing-aligned,
│   ┌─────────────┐        ┌─────────────────┐│     directly above the action row
│   │  🚩 Report   │        │  📍 Park Here    ││
│   └─────────────┘        └─────────────────┘│
│ ┌───────────────────────────────────────────┐│
│ │ W 34 ST  …                                 ││
```

Recenter is **not** a third capsule crammed into the action row (see "bad ideas," below) — it's a
compact circular button (matches the real Apple Maps recenter affordance) that stacks structurally
above the action row inside the same `VStack`. Because it's laid out in-flow rather than
independently `Spacer()`-positioned, it never needs a hand-maintained clearance function — it just
pushes whatever's below it down, the same way adding a row to any `VStack` does. This is a
maintenance win, not just a visual one: `recenterPillBottomPadding` (`ContentView.swift:2709–2714`)
can be deleted once this lands.

### S3 — destination mode, approaching (strip inside the card, unchanged)

```
│   ┌─────────────┐        ┌─────────────────┐│
│   │  🚩 Report   │        │  📍 Park Here    ││
│   └─────────────┘        └─────────────────┘│
│ ┌───────────────────────────────────────────┐│
│ │ 📍 Approaching destination                 ││  ← unchanged, already inside the card
│ │ W 34 ST            0.2 mi          🔊      ││
│ │ LEFT    Free until 9:30 AM                 ││
│ │ RIGHT   No parking                         ││
│ └───────────────────────────────────────────┘│
```

### S5/S6 — Park Until pill carried over, worst case (+ approaching, + paused)

```
│                                    ⊙          │  ← Recenter (S4)
│   ┌─────────────┐        ┌─────────────────┐│  ← action row
│   │  🚩 Report   │        │  📍 Park Here    ││
│   └─────────────┘        └─────────────────┘│
│ ┌───────────────────────────────────────────┐│
│ │ ●  Until 6:00 PM                    ✕      ││  ← ParkUntilPill (unchanged component)
│ └───────────────────────────────────────────┘│
│ ┌───────────────────────────────────────────┐│
│ │ 📍 Approaching destination                 ││  ← approach strip + card
│ │ W 34 ST            0.2 mi          🔊      ││
│ │ LEFT    Free until 9:30 AM                 ││
│ │ RIGHT   No parking                         ││
│ └───────────────────────────────────────────┘│
```

All four optional rows (Recenter / action row / Park Until pill / card) are siblings in one
`VStack(spacing: 8)`, `.padding(.horizontal, 16)` for everything except the card (which stays
edge-to-edge, unchanged). No combination needs bespoke padding math — that's the point.

### S1 — placeholder ("Looking for street…")

Action row is unaffected (it doesn't depend on `drivingContext`); only the card shrinks to its
existing shorter placeholder layout. No new interaction needed.

---

## Proposal 2 — Coordinated Two-Zone (lower-risk alternative)

**Thesis:** keep the existing two-zone shape (a top row, a bottom stack) but actually reconcile
them, rather than relocating the destructive control. Lower engineering risk — it doesn't touch
`ContentView.swift`'s top-left corner logic as invasively, which matters because that region is
flagged as contended with FT-15/FT-17a. Doesn't fully satisfy "all buttons on the bottom," but
removes the two-cluster problem by **deleting** the redundant top-right toolbar during Drive Mode
(same F4 fix as Proposal 1) and unifying the top row.

### Layout (steady state)

```
│ ASP in Effect Today                            │
├─────────────────────────────────────────────┤
│  ⓧ End Cruise        🔊                        │  ← single top row: End + mute,
│                                                │     left-anchored, no dead-space Spacer
│              MAP                               │
│                                                │
│                                    ⊙ Recenter  │  ← conditional, bottom-right, above dock
│   ┌─────────────┐        ┌─────────────────┐│
│   │  🚩 Report   │        │  📍 Park Here    ││
│   └─────────────┘        └─────────────────┘│
│ ┌───────────────────────────────────────────┐│
│ │ W 34 ST …                                   ││
```

Gear button, guide button, and the entire top-right toolbar are hidden during Drive Mode exactly
as in Proposal 1 (that fix is independent of which proposal ships — it's F4, a bug fix either way).
The difference from Proposal 1 is narrower: End Drive/Cruise (and, in Cruise Mode, mute — though
mute is *also* de-duplicated per F3 regardless of which proposal ships, so in practice this top row
often just has one control, End) stays at the top, in its pre-existing muscle-memory position,
rather than moving to a small isolated icon. This is closer to today's actual behavior and cheaper
to implement and re-test, at the cost of not being a true single bottom-anchored cluster.

All bottom-stack states (S1–S6) are identical to Proposal 1 — the only difference between the two
proposals is where End Drive/Cruise lives.

---

## Recommendation

**Proposal 1**, with the End control's placement explicitly confirmed by Kevin first (see Open
Questions — it's the one place this proposal deviates from his literal framing, and I'd rather
flag that up front than have him discover it in a build).

Proposal 2 is the right fallback if engineering wants to de-risk the change given the
`ContentView.swift` contention note in `docs/field-testing-log.md` (FT-15 Stream B2 / FT-17a both
touch this file) — it delivers most of the decluttering (F1, F3, F4 all fixed) with a smaller diff,
and can be a stepping stone to Proposal 1 later rather than a dead end.

---

## Is "all buttons on the bottom" actually right? (flagging Kevin's framing directly)

Partially, and I'd push back on one piece of it rather than silently reinterpret it.

**Where it's right:** Report and Park Here are the two things a driver actually reaches for
repeatedly during a session, and Apple Maps' own bottom ETA bar is exactly this pattern — the
frequent, low-risk actions live in one bottom-anchored, thumb-reachable cluster. Moving them there,
in one language, fixes the actual "looks bad" complaint.

**Where I'd push back:** ending Drive Mode is not the same risk class as reporting an enforcement
sighting or confirming a park. It's a one-tap, no-confirmation, session-terminating action
(`endDriveMode()` fires immediately, `ContentView.swift:1621–1630` — no dialog). Putting it in the
same reachable cluster as Report/Park Here, at the bottom of a phone that's mounted for one-handed
use while the car is moving, is the layout most likely to produce an accidental "End Cruise" mid-
search. **Apple Maps' own turn-by-turn view doesn't put its End control in the primary bottom
action cluster either** — it's isolated in its own corner specifically so it isn't adjacent to the
buttons you tap routinely. I'm recommending WePark follow that precedent rather than the literal
"everything at the bottom" reading — same declutter outcome, same "clean" outcome, one safety-
motivated exception, named explicitly rather than silently applied.

If Kevin disagrees and wants End literally in the bottom stack: put it in its own row, bottom-
**left**, small and outline-styled (not filled red), as far from Park Here/Report (bottom-right) as
the row allows — never adjacent. I'd still recommend against it, but that's the least-bad version
of the literal ask.

---

## Per-control disposition

| Control | Disposition | Where today | Reasoning |
|---|---|---|---|
| ASP Banner | **Keep, unchanged** | `ASPBanner.swift`, top `safeAreaInset` | Already correct pattern (pushes content, doesn't overlay); out of scope (color-coded ground truth). |
| Gear / Settings button | **Hide during Drive Mode** | `gearButtonOverlay`, `ContentView.swift:1146–1181` | Not needed mid-drive; currently visually collides with End Drive pill (F2). Extend the existing `parkingGuideButtonVisible` gating pattern (`:2682–2684`) to gear. |
| Parking 101 guide (?) button | **No change** | already hidden via `parkingGuideButtonVisible` | Already correctly gated. |
| "Find me" | **Remove during Drive Mode; functionally merged into Recenter** | `recenterButtonStack`, `:1308–1319` | Uses the wrong (browse) camera pipeline mid-drive (F4). Recenter pill already does the correct equivalent exactly when needed (`followPaused == true`). No functionality lost — the only case removed is force-recentering while follow is already active, which is a no-op. |
| "Find my car" | **Remove during Drive Mode** | `recenterButtonStack`, `:1321–1334` | Same wrong-pipeline bug (F4) plus disorienting mid-drive jump to a possibly-distant pin. **Cost, named explicitly:** driver loses the ability to glance at their previously-parked car's location without ending Drive Mode first. If Kevin wants it back, it can return as a third small icon next to Recenter — see Open Questions. |
| Park Until entry (clock icon) | **Remove entry during Drive Mode; keep the pill if already active** | `recenterButtonStack`, `:1336–1348` | Setting a new time-filter mid-drive isn't a realistic use case (you're now driving to/toward a spot, not comparison-shopping blocks). `ParkUntilPill`, if already active from browsing, stays visible and clearable in the bottom stack (S5/S6) — nothing already-set is lost, only new mid-drive entry. |
| Combined Drive-entry button (4th, resting icon) | **Remove during Drive Mode** | `recenterButtonStack`, `:1360–1374` | Currently non-functional during drive (explicit "No action on tap" comment) — a decoy affordance, not a design choice; should never have rendered as tappable-looking. |
| End Drive / End Cruise | **Keep, relocate + demote visually** | `driveModeOverlayLayer`, `:1442–1458` | Isolate top-trailing, small (44pt floor, not larger), `.regularMaterial` not filled-red, short "End" label. See "all buttons on bottom" section above for the full reasoning. |
| Mute toggle (top-row, cruise-only copy) | **Delete** | `driveModeOverlayLayer`, `:1463–1475` | Exact duplicate of `DriveModeBottomCard.muteButton` (F3) — same state, two renders. `DriveModeBottomCard`'s copy already handles both Cruise and Destination correctly (it's unconditional); deleting the top copy is a pure bug fix, zero functionality lost. |
| Report | **Keep, move to bottom action row** | `driveModeOverlayLayer`, `:1489–1516` | Anatomy already fixed (P2-1); only position and margins change. |
| Park Here | **Keep, move to bottom action row, make visually primary** | `driveModeOverlayLayer`, `:1526–1556` | Same anatomy fix already landed; give it the filled/prominent treatment since it's the session's actual goal action. |
| Recenter pill | **Keep, restyle to small circular icon button, restructure into the stacking `VStack`** | `driveModeOverlayLayer`, `:1568–1584` | Removes the need for hand-computed clearance (`recenterPillBottomPadding` can be deleted once this lands); matches Apple Maps' own compact recenter affordance. |
| Approach strip | **No change** | `DriveModeBottomCard.swift:82–96` | Already lives inside the card correctly; not part of this pass. |
| Street + L/R chips card | **No change (position or content)** | `DriveModeBottomCard.swift` | This is the "ground truth" slab — full-width, anchored, visually distinct from the floating action controls above it. That distinction (floating capsules = things you do; anchored slab = the fact you're reading) is the organizing idea behind Proposal 1, not something to blur. |
| Park Until pill | **No change** | `ParkUntilSheet.swift:256–289` | Already uses the correct 16pt-margin convention — this is the template the other floating rows should match, not the other way around. |

---

## Spacing / sizing / contrast spec

For whichever proposal ships:

- **Bottom stack horizontal margins:** `16pt` both sides for every floating row (Recenter row,
  action row, `ParkUntilPill`) — matches `ParkUntilPill`'s existing values exactly, no new constant.
  `DriveModeBottomCard` itself stays edge-to-edge (unchanged).
- **Vertical gap between stacked rows:** `8pt`, via a single `VStack(spacing: 8)` wrapping
  Recenter / action row / `ParkUntilPill` / card, replacing the independent `Spacer()`-positioned
  floating elements in `driveModeOverlayLayer` today.
- **Action row buttons (Report, Park Here):** capsule, `Label(icon, text)`, `.subheadline.weight(.semibold)`,
  horizontal padding `18pt` (up from the current `14–16pt` — Kevin's core complaint is spacing, so
  err generous here), vertical padding `12pt` (up from `10pt`), explicit `.frame(minHeight: 48)`
  (4pt above the HIG 44pt floor — cheap insurance on a control tapped at speed), `16pt` gap between
  the two buttons (not the current `10pt`).
- **Park Here (primary):** solid `Color.accentColor` fill, white/system text — matches the existing
  "primary CTA" treatment used elsewhere in the app, no new color.
- **Report (secondary):** keep current `.regularMaterial` + `Color.orange` text treatment — already
  passed the P2-1 anatomy pass, no need to re-touch besides the padding bump above.
- **Recenter (circular):** `48×48pt`, `Circle()`, `.regularMaterial` background, `Color.accentColor`
  icon (`location.fill` or `location.north.line.fill`), trailing-aligned within its own row.
- **End control:** `.frame(minHeight: 44)` (system floor only — deliberately not enlarged),
  `.regularMaterial` background, `Color.red` icon + short "End" text (not "End Drive Mode" — shorter
  chrome, `accessibilityLabel` carries the full "End Drive Mode" / "End Cruise Mode" string for
  VoiceOver same as today). Top padding: reuse `paddingForBannerState(bannerState)` unchanged
  (`100pt`, already tested). Trailing padding `12pt`.
- **Gear button:** hidden during Drive Mode — no sizing change, just add
  `gearButtonVisible(driveModeActive:)` (mirror `parkingGuideButtonVisible`, `:2682–2684`) and gate
  `gearButtonOverlay`'s render on it.
- **Contrast:** no new colors. Reuse the TF2-18 P1-1 solid-fill-plus-dark-or-white-text recipe
  (`DriveModeBottomCard.swift:193–245`) for Park Here's filled state if a new fill is needed;
  otherwise everything here reuses existing `.regularMaterial`/`accentColor`/`.red`/`.orange` values
  already in the codebase.
- **Corner radii:** capsules stay native capsule shape; the two circular buttons (Recenter, and
  optionally End if Kevin picks the circular variant) use `Circle()`. No new radius tokens
  introduced.
- **Code cleanup that falls out of this, not extra scope:** `recenterPillBottomPadding`
  (`ContentView.swift:2709–2714`) can be deleted once Recenter is a structural `VStack` row instead
  of an independently-`Spacer()`-positioned float — the four hardcoded heights it encodes become
  unnecessary. `paddingForBannerState` stays (still needed for the End control's top clearance).

---

## ✅ KEVIN'S DECISIONS — 2026-08-13 (all five closed, do not re-open)

| # | Question | **Ruling** |
|---|---|---|
| 1 | End control placement | **Match Apple Maps** — isolated top-trailing icon, NOT in the bottom action cluster. The designer's safety argument is accepted: End Drive is a one-tap, no-confirmation, session-terminating action and must not sit adjacent to Report/Park Here on a phone mounted in a moving car. |
| 2 | "Find my car" during Drive Mode | **Remove it.** Not kept as a small icon. Its broken `recenterMap()` browse-path call (bug F4) disappears with it. |
| 3 | Gear button during Drive Mode | **Hide it fully.** Not dimmed-but-tappable. Voice control stays reachable via the always-visible mute button in the bottom card. Resolves the F2 coordinate collision with the End pill. |
| 4 | Report / Park Here ordering | **Park Here trailing** — it is the primary "I'm done" action and gets the thumb-natural position. |
| 5 | Which proposal | **Proposal 1 — Bottom Dock.** Not the lower-risk Coordinated Two-Zone alternative. |

**Implementation notes that follow from these rulings:**
- All four bugs (F1 trailing `Spacer()`, F2 gear/End collision, F3 duplicated mute toggle, F4 broken
  mid-drive camera path) are in scope — they live in the same code the redesign rewrites, and fixing
  them separately would mean touching `ContentView.swift` twice.
- The layout must hold across **all 7 enumerated states**, including S6 (destination + approaching +
  follow-paused + Park Until stacked). A layout that only works in the steady state is not done.
- **Sequencing:** this work touches `ContentView.swift`, which is contended. It must land **after
  PR #74 (FT-17a)** merges — #74 modifies `recenterDriveMode()` in the same file — and it must be
  coordinated with **FT-15 Stream B2**, which also wants that file.

---

## ✅ ON-DEVICE VALIDATION — Kevin, 2026-08-18 (simulator smoke of PR #79)

- **"I do like the new button design on drive mode."** Bottom Dock validated.
- **Recenter: labeled pill → plain blue icon.** Kevin: *"the recenter pill is gone. It's just the
  blue icon which I think works. That's what Apple Maps does."* **APPROVED.** Recording it because
  this was NOT one of the five rulings — it emerged during implementation and Kevin endorsed it
  after seeing it. Do not "restore" the labeled pill in a later pass.
- **Gear hidden in Drive Mode + exactly one mute button** (bottom card only) — confirmed.
- **FT-17a not regressed** — *"zoom and recenter looks great."*
- **ParkUntil-pill stacking order (§S5/S6): ✅ VERIFIED.** Kevin set a park-until time to reach the
  state and confirmed the pill sits above the bottom card and *"looks good as is."* This resolves the
  implementing agent's flagged interpretation call — it read the doc's ASCII diagrams as authoritative
  over the terser "No change" disposition-table entries, and that reading was correct.

---

## Open Questions

1. **End control placement** — top-trailing isolated icon (my recommendation) vs. literally in the
   bottom stack, bottom-left, spatially separated from Report/Park Here (the least-bad version of
   the literal "all on bottom" ask)? This is the one real design decision in this doc; everything
   else follows from Apple Maps precedent + existing bugs.
2. **"Find my car" during Drive Mode** — fully removed (my recommendation, cost named above), or
   kept as a third small icon next to Recenter? If kept, it needs the flat-recenter bug (F4) fixed
   regardless — it can't keep using `recenterMap()`'s browse pipeline.
3. **Gear button during Drive Mode** — fully hidden (my recommendation) or dimmed to ~40% opacity
   and kept tappable, in case Kevin wants mid-drive access to a setting (most likely voice-related,
   which is already covered by the always-visible mute button in the bottom card)?
4. **Report/Park Here ordering** — Park Here trailing (primary, thumb-natural for the "I'm done"
   action) vs. leading? Low-stakes, easy to flip either direction during implementation.
5. **Confirmation on End** — this proposal keeps End as a single, unconfirmed tap (matching
   today's behavior) and relies on placement + de-emphasis instead of a confirm dialog to prevent
   mis-taps (a confirm dialog is itself a mid-drive interaction risk). If real-device testing shows
   mis-taps are still happening even with the isolated placement, a "press and hold" pattern would
   be the next escalation — flagging as a future idea, not proposing it now.

---

## Explicitly flagged as bad ideas

- **Literal "every control including End Drive in one bottom cluster."** Addressed at length above
  — real mis-tap risk for a session-ending action, and Apple Maps' own reference layout doesn't do
  this either.
- **Recenter as a third capsule in the Report/Park Here row.** Doesn't fit comfortably on a 375pt-
  wide phone (16+16 margins + 2×12 spacing leaves ~319pt for three labeled capsules — tight enough
  to fight the "generous breathing room" goal this whole redesign is for) and it's a different kind
  of control (urgent, one-off correction vs. steady-state action) — visually conflating the two
  undoes the "one control language" clarity this proposal is trying to establish. Keep Recenter as
  its own small circular affordance.
- **Re-theming the ASP banner to look more like a Maps maneuver banner.** Out of scope — WePark has
  no turn-by-turn maneuver data to show, and the ASP banner already correctly owns "day-level ASP
  status," a different fact from anything Apple Maps' top banner communicates. Don't conflate the
  two just because both are top banners.
- **Hiding the browse-mode toolbar via animation/fade instead of a hard conditional.** Tempting for
  polish, but this surface has a documented history of regressions around Drive Mode camera/gesture
  state (`docs/tf2-11-drive-camera-ownership-spec.md`, the "#31 saga" referenced throughout
  `ContentView.swift`). A plain `if driveModeActive { }` conditional (matching the existing
  `parkingGuideButtonVisible` pattern already in the codebase) is the lower-risk choice; a
  transition/animation pass can be a follow-up once the structural change is verified stable.

---

## What's working

- **`ASPBanner`'s `safeAreaInset` pattern is still the right model** — it reserves space rather than
  floating over content, which is exactly the "minimal chrome over live content" principle this
  whole redesign is chasing for the rest of the surface.
- **The TF2-18 contrast fix (P1-1) is real and should not be re-touched** — solid-fill chips at
  ~4.9–12:1 in both appearances is a genuine, measured improvement over the pre-fix ~1.4–2.6:1, and
  nothing in this proposal changes chip color logic.
- **The button-anatomy unification (P2-1) did its job** — Report, Park Here, and End Drive already
  share one capsule + `Label` shape with explicit `minHeight: 44`. This proposal reuses that
  anatomy rather than inventing a new one; the remaining work is compositional (where things live),
  not stylistic (how each button is drawn).
- **`DriveModeBottomCard`'s mute button is the correct pattern already** — 44×44pt invisible tap
  frame around a 36pt visual glyph, explicit HIG-minimum comment in the code. It should simply
  become the *only* mute button (F3), not be redesigned.
- **`ParkUntilPill`'s 16pt-margin inset-capsule convention is exactly the shared bottom-stack
  language the rest of this surface should adopt** — it's already correct; this proposal makes
  everything else match it instead of the reverse.
- **No webview tells anywhere in this surface** — SF Symbols throughout, system fonts via semantic
  styles (`.headline`/`.subheadline`/`.caption`), native `Menu`/`.sheet`/`confirmationDialog`. The
  redesign here is entirely about composition and z-order, not about replacing any of this.
