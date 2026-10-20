# Goal-first ambient screen — design pass

**Status:** Design spec for @ios-engineer, 2026-10-20. Commissioned by `docs/drive-mode-default-spec.md`
§4's designer row. Binds to Kevin's rulings 4 and 5 (2026-10-20, locked) and AC-31's no-evasion-language
constraint. Does not relitigate the three-goals/Free-Overnight-default/one-flag/strict-few-hours
rulings — designs within them.
**Owner:** @designer.
**Reads before building against this:** `docs/drive-mode-default-spec.md` §0.8 in full (§0.8.1–§0.8.10),
§0.4/§0.4a, §2.1 item 10/13/14/15, §3.3's file table, §5 AC-21–AC-32.

---

## 0. The one correction to the spec's own placeholder copy — read this first

§0.8.1's placeholder table pairs "Free overnight" and "Park & forget" with the word **"Free"** right
in the primary label. The spec's own text two paragraphs later (§0.8.2) is explicit that this must
**never mean free-of-charge** — the promise is "won't need to move it," meters may still apply. Putting
the word "Free" in the button itself, at the size and prominence Kevin's ruling demands, is the single
highest-risk place for that ambiguity to land: it's the first word a half-attentive driver reads.

**Fix, applied once, structurally, not per-button:** drop "Free" from both ambiguous buttons' primary
label entirely. Say the actual promise — "won't need to move it" / "no meter, no cost" — as a second,
smaller line under a short, concrete primary word. This also makes the two buttons' *different*
promises textually explicit side by side, which is the actual job AC-31's constraint is protecting:
Overnight and Park & Forget share one promise family ("won't move it"); Few Hours has a different,
stricter one ("no cost at all"). Putting both promises in writing, in parallel positions, is cheaper
and more honest than trying to make one adjective ("Free") carry two different meanings across two
buttons.

Internal naming is unaffected — keep `ParkingGoal.freeOvernight` / "Free Overnight" as the engine/AC
identifier (matches §0.8.1–§0.8.10, AC-21–AC-32 verbatim). Only the **rendered string** changes.

---

## 1. Exact copy + icons

| Goal | SF Symbol | Primary (bold) | Sub-label (secondary) | One-line rationale |
|---|---|---|---|---|
| **Overnight** (default, pre-selected) | `moon.stars.fill` | **Overnight** | Won't need to move it | Moon = universal "nighttime," zero NYC jargon. Sub-label states the actual promise (not "free") directly, per §0. |
| **A Few Hours** | `hourglass` | **A Few Hours** | No meter, no cost | Deliberately NOT `clock.fill` — that symbol is reserved elsewhere in this app for the power-user Park Until sheet's own toolbar entry point (`recenterButtonStack` button 3); reusing it here on the same screen would make two different controls look like the same control. Sub-label states the strict, different promise (§0.8.5) in the same two-line shape as Overnight, so a side-by-side read makes the distinction self-evident without a tooltip. |
| **Park & Forget** | `parkingsign.circle.fill` | **Park & Forget** | Go days without moving it | Kevin's own placeholder wording kept verbatim — it's already a familiar, jargon-free idiom ("set it and forget it"). Icon reads "parking" directly, beats 🅿️-as-emoji for native feel (matches this doc's iOS bias — SF Symbol, not emoji). Sub-label reuses the "...moving it" phrasing from Overnight's sub-label on purpose: once a user reads one, the other's family is instantly legible as "same kind of promise, longer." |
| **Secondary escalation** ("start driving") | `location.north.circle.fill` | Start Driving | *(no sub-label — see §2)* | Kevin's own suggested wording (§0.8.7), kept. Icon previews the heading-up chevron the user is about to see in Cruise, without reusing `car.fill` (already means "find my car" elsewhere on this exact screen). |
| **Full-palette toggle** | `paintpalette.fill` | Show all parking rules | *(flips to "Back to goal picker" once toggled on — see §2)* | Literal, honest, matches the internal "5-color palette" mental model without saying "filter" or any engine-y word. `paintpalette.fill` reads as "the full-color version" at a glance; distinct from every other icon on screen. |

All copy checked against AC-31: no "avoid/ticket/fine/evasion/dodge" anywhere above.

---

## 2. Layout — the ambient control stack

**My single biggest layout call: a horizontal row of three big square-ish tiles, not three stacked
full-width rows, anchored as a NEW ambient-only bottom dock — mutually exclusive with Drive Mode's
existing `bottomSafeAreaContent`, same "exactly one bottom stack visible at a time" discipline that
file already enforces between its own rows.** Rationale: Kevin's ask is for *buttons, plural, that
read as one choice of three* — a side-by-side row is the correct gestalt for "pick one of three
mutually exclusive options" (segmented-control mental model), reads faster than a vertical list, and
costs noticeably less vertical map real estate than three stacked full-width rows while still clearing
every touch-target minimum by more than 2×.

### 2.1 Structure, bottom-anchored `VStack(spacing: 10)` inside `.safeAreaInset(edge: .bottom)`, 16pt horizontal margins, top-to-bottom code order (closest-to-thumb = last/bottom):

```
VStack(spacing: 10) {
    fullPaletteToggleRow           // quietest, farthest from thumb, rarely used
    if showsEmptyMapGuard { emptyMapGuardBanner }   // contextual, appears just above the action
    startDrivingRow                 // demoted secondary — deliberate extra reach above the tiles
    goalTileRow                     // biggest, closest to thumb, the centerpiece
}
.padding(.horizontal, 16)
.padding(.bottom, 8)
```

No enclosing card/panel wraps the whole stack — each row keeps its own independent background
(matching `bottomSafeAreaContent`'s existing per-row styling convention). This keeps slivers of live
map visible between rows, reinforcing "the map is still the product," not a modal panel bolted on top
of it.

**Why "Start Driving" sits ABOVE the tiles, not below/closest-to-thumb:** the tiles are the low-risk,
reversible, one-tap action (just re-filters the map). "Start Driving" is the one control in this stack
that changes posture — continuous GPS, heading-up camera, voice, wake lock (§3.1's two-posture model).
Putting it one deliberate reach above the resting thumb position, rather than at the very edge, costs
one extra half-inch of thumb travel and meaningfully cuts the odds of an accidental escalation tap —
cheap insurance for a control with real side effects.

### 2.2 Goal tile row

```
HStack(spacing: 10) {
    GoalTile(.overnight)     // .frame(maxWidth: .infinity, minHeight: 112)
    GoalTile(.fewHours)
    GoalTile(.parkForget)
}
```

Each tile:
- `RoundedRectangle(cornerRadius: 20)` background.
- **Selected** (the currently active goal — Overnight by default): fill `Color.blue`, icon + primary
  label `.white`, sub-label `.white.opacity(0.85)`. **Unselected**: fill `Color(.systemGray6)`, icon +
  both labels `.secondary`. This is the exact filled-blue-capsule idiom already shipped in
  `ReportSheet.sweeperDirectionRow` (`Color.blue` fill + white text when selected, `Color(.systemGray6)`
  + secondary when not) and `CrewFeedSection.zoneChip` — ported from a capsule to a bigger rounded-rect
  tile, same color logic, same "no extra checkmark glyph needed, the fill IS the selected state" choice
  `sweeperDirectionRow` already makes (don't copy `reportTypeRow`'s trailing-checkmark pattern here —
  it doesn't fit this layout and the fill-only version is simpler to read at a glance, which matters
  more here than anywhere else in the app).
- **Deliberately NOT green for the selected state**, even though green is the "good/active" color
  everywhere else conceptually. Green/red on this screen already mean something specific and sacred —
  the map's binary filtered answer. Using green for button-selection chrome would blur "this button is
  currently picked" with "this curb is currently fine," two different channels that must stay visually
  separate. Blue is the established, correct, semantically distinct UI-selection color per the two cited
  precedents — hold the line here even though it'd be tempting to reach for green.
- Internal layout: `VStack(spacing: 6)` — icon (`.font(.title2)`, NOT a fixed point size, so it scales
  with Dynamic Type — see §2.5) — primary label (`.font(.headline)`, bold, centered, up to 2 lines) —
  sub-label (`.font(.caption)`, centered, up to 2 lines).
- `.buttonStyle(.plain)`, `.contentShape(Rectangle())`, `.accessibilityLabel("<Primary>, <sub-label as a
  full sentence>")` (e.g. "Overnight, won't need to move it"), `.accessibilityAddTraits(isSelected ?
  [.isSelected] : [])` — same pattern as `reportTypeRow`/`subTagPickerRow` already use.
- Tap behavior: sets the goal, calls `rebuildOverlays()` via the existing `parkUntilMode`/
  `parkUntilTarget` path (§0.8.6) — **no confirm step, no sheet** (AC-22).

### 2.3 Secondary "Start Driving" row

Full-width `.buttonStyle(.bordered)` (NOT `.borderedProminent` — the outline-not-filled treatment is
itself part of how this reads as demoted, on top of its smaller height), `RoundedRectangle(cornerRadius:
14)`, `.frame(minHeight: 48)`. `Label("Start Driving", systemImage: "location.north.circle.fill")`,
`.font(.subheadline.weight(.semibold))`. One line only — no sub-label, deliberately, so it doesn't
visually compete with the two-line tiles below it.

**Behavior note, not covered mechanically by the spec:** keep this row visible and functional in BOTH
goal-first and full-palette modes (unconditional on the full-palette toggle) — a user who's switched to
full-palette still needs a way to enter Cruise. Only the goal-tile row itself should hide when toggled
to full-palette (§2.4).

### 2.4 Full-palette toggle row

Smallest, quietest element — but still backed by `.regularMaterial`, not bare text floating on the live
map. (Every other floating control in this app — Report pill, "?" button, recenter stack, `ParkUntilPill`
— uses a material background over the map for exactly this reason: a live map underneath has
unpredictable color/contrast, and naked text would be the first legibility bug of its kind in this
codebase.) Small `Capsule()`, `.padding(.horizontal, 12).padding(.vertical, 6)`, `.font(.footnote
.weight(.medium))`, icon at `.font(.caption)`. `.frame(minHeight: 44)` on the tappable area even though
the visible capsule is small — quiet visually, still a full touch target.

Label flips with state: **"Show all parking rules"** (goal-first active) ↔ **"Back to goal picker"**
(full-palette active). This reverse-direction label isn't specified mechanically in §0.8.8 — flagging
it explicitly so the toggle doesn't ship one-directional.

When toggled to full-palette: the goal-tile row (§2.2) hides entirely; the clock-icon power-user entry
point reappears in `recenterButtonStack` (§2.6); "Start Driving" (§2.3) stays visible per §2.3's note.

### 2.5 Dynamic Type — a deliberate departure from some existing fixed-size precedent

Several existing call sites in this codebase use fixed `.system(size: N)` for icons/text (e.g.
`reportTypeRow`'s `.font(.system(size: 22, weight: .semibold))`, `recenterButtonStack`'s `.font(.system(
size: 17, weight: .medium))`). For this screen specifically, use semantic, Dynamic-Type-scalable styles
throughout (`.headline`, `.subheadline`, `.caption`, `.footnote`, `.title2` for icons) instead. Kevin's
own bar for this screen — "anyone who boots it up should get it" — is undermined if a Large-Text
accessibility user is the one person these "biggest, unmistakable" buttons *don't* scale for. This is a
scoped exception for the goal-first surface, not a request to retrofit the rest of the file.

### 2.6 Persistent Search icon (§0.4) + the clock icon's new conditional visibility

Insert the Search icon into the existing `recenterButtonStack` (top-right, same 44×44pt `.regularMaterial`
circle family, per §0.4's own instruction) as the stack's 2nd button — after "Find me," before the
conditional "Find my car" — `Image(systemName: "magnifyingglass")`, same frame/background/foreground
treatment as the other two circles. Tap presents `.browseNav` at `.medium` detent (§0.4a's Job B fix).

**Concrete gating note for the clock-icon button (button 3 today):** §0.8.9 says the power-user
`ParkUntilSheet` clock icon "is not reachable directly from the goal-first home screen." Make this
literal: hide the clock-icon button from `recenterButtonStack` while the goal-first dock is showing
(i.e., while `!fullPaletteMode`), and show it again once the user has toggled to full-palette (§2.4).
This isn't spelled out as a code change anywhere else in the spec — it's a real, small, necessary edit
to `recenterButtonStackVisible`'s sibling logic, flagging it here so it doesn't get missed.

---

## 3. "Good through <day>" label + empty-map guard banner

### 3.1 "Good through <day>" (§0.8.3a)

**Where it renders:** the existing block-detail sheet's safety-label line (first element, big text —
`docs/design/ios-mvp-palette.md` §5.1's own "color is the glance layer, text is the truth layer"
principle already establishes this is where per-block nuance belongs). When a goal filter is active and
the tapped segment is in the matching (green) bucket, this line reads **"Good through <relative day>"**
instead of the normal "Free until..." phrasing. No new on-map badge, no new color, no ambient summary
line — §6 of the spec explicitly defers a "richer nearby-free-blocks ambient summary" as future work;
this stays scoped to what's already asked for.

**Format:** new pure formatter in `ParkingGoals.swift`, same three-tier shape as
`ParkUntilSheet.formatTime` but date-only (no time-of-day component, since the ladder deals in whole
calendar days):
- Tomorrow → **"Good through tomorrow"**
- 2–6 days out → **"Good through <EEE>"** (e.g. "Good through Thu")
- 7+ days out → **"Good through <MMM d>"** (e.g. "Good through May 25")

Never render "Good through today" — if the ladder ever resolves to a same-day rung (shouldn't happen
given the 2-day floor, but defensively), fall back to "Good through tomorrow" rather than a
same-day-sounding label that reads like it's already expired.

### 3.2 Empty-map guard banner (§0.8.10)

One component, two copy states, **identical neutral styling for both** — deliberately NOT color-coded
by severity. `Color.red`/`.orange` are reserved for "you can't park here" in the sacred 5-color palette;
reusing either for an unrelated "didn't find much" UI state would teach users the wrong association and
is exactly the kind of palette drift this review exists to catch. Both states: `.regularMaterial`,
`RoundedRectangle(cornerRadius: 14)`, `.padding(.horizontal, 14).padding(.vertical, 10)`, leading icon +
`.font(.subheadline)` text, differentiated ONLY by icon + copy:

| State | Icon | Copy |
|---|---|---|
| Soft ("ladder stepped down") | `info.circle.fill` | "Nothing clear for a full week nearby — showing the best available." |
| True-empty (even the 2-day floor fails) | `mappin.slash` | "No clear spots found very nearby — try Overnight, or pan the map." |

(Note: copy updated from the spec's own placeholder "try Free Overnight" to "try Overnight," matching
§0's button-label fix — keep banner and button vocabulary identical so a user can act on the banner's
suggestion by recognizing the same word on the tile below it.)

Position: directly above the "Start Driving" row (§2.1) — contextually tied to the goal just picked,
appearing right where the user's eye already is rather than requiring a look up to a top banner reserved
for the unrelated citywide ASP-suspension channel (`ASPBanner`). No dismiss button — it's a live readout
of current viewport + goal state, not a one-time notice; it disappears on its own once the user pans,
zooms, or picks a different goal.

---

## 4. Priming-card copy check (§0.2)

Spec's draft: *"See real parking conditions around you — allow location."* **Confirmed, with one small
tightening:** drop "real" (a filler adjective that reads slightly marketing-voice next to this app's
otherwise plain, utilitarian copy) →

> **"See parking conditions around you."** Button: **"Allow."** Secondary: **"Not now."**

Kept intentionally generic/location-focused, not goal-specific — this is a permissions-priming moment,
not a feature tour. Mixing in "see if you'll need to move your car tonight" would overpromise before the
user has even picked a goal, and would violate the "no nag, no onboarding links visible" posture this
spec already holds itself to (§0.1's "Must NOT" list).

---

## 5. First-time-user comprehension walkthrough (the test Kevin's ruling demands)

Cold launch, zero context, first 5 seconds:

**0:00** — App opens. No sheet to dismiss, nothing to read first. Full screen: map, a binary green/red
pattern on the visible blocks (not the busy 5-color version — goal-first always renders exactly 2
colors), blue dot roughly at the user's position (or city-center fallback), and a dense, high-contrast
control cluster anchored to the bottom third of the screen, sitting right above the thumb.

**0:00–1s** — Eye goes straight to the bottom cluster: it's the single largest, highest-contrast, most
physically reachable group of shapes on screen. Three big tiles dominate it. One is visibly different —
filled solid blue, white icon and text — the other two are neutral gray.

**1–2s** — Without reading anything yet, the user registers: *there are three options here, and one of
them is already chosen* (the filled-vs-gray contrast alone communicates "selected" before any text is
parsed — this is the entire point of the filled-capsule idiom).

**2–3s** — Reads the selected tile: moon icon, **"Overnight"**, **"Won't need to move it."** Lands
immediately on the actual value prop with zero NYC-specific vocabulary required: *this screen is already
telling me whether I can leave my car overnight without having to deal with it tomorrow.*

**3–4s** — Peripheral read of the other two: hourglass/**"A Few Hours"**/"No meter, no cost" and
P-sign/**"Park & Forget"**/"Go days without moving it." Both are self-explanatory without any parking
expertise — the user correctly infers these are alternative questions they could ask instead, each
answered the same way (green/red on the map).

**4–5s** — Notices the quieter, outlined "Start Driving" pill sitting just above the three tiles and
correctly reads it as a *different, secondary* action from the three big choices — probably "go,
actually navigate" — without needing to tap it to find out, because its visual weight (smaller, outlined,
one line, no fill) is deliberately lighter than the tiles.

**At 5 seconds:** the user understands (a) three big buttons = three things they might want from
parking, (b) one is already active and the map is already answering it, (c) green/red on the map = good/
no-good for whatever's picked, (d) there's a separate "go drive" action they haven't triggered yet. They
do **not** yet understand ASP side-swap mechanics, the metered-tolerance distinction, or the step-down
ladder — which is explicitly fine per Kevin's own bar ("maybe not the ASP rules but at least get the
buttons").

**Recommendation for @qa-verifier / Kevin's smoke:** this walkthrough is only as good as the literal
copy/icons shipped. Before or alongside AC-31's smoke, show a cold screenshot of this screen to one or
two people with zero NYC-parking context and ask "what do you think these three buttons do?" — a $0,
five-minute comprehension check that catches a copy regression a screenshot diff can't.

---

## 6. Flags for @ios-engineer (concrete, not a redesign ask)

1. **Suppress the legacy `ParkUntilPill` row while the goal-first dock is showing.** `ParkUntilPill`
   (`ContentView.swift`'s `bottomSafeAreaContent`, the `if parkUntilMode, let target = parkUntilTarget`
   row) is gated only on `parkUntilMode`/`parkUntilTarget`, not on `driveModeActive` — it already renders
   at rest today whenever Park Until is active. Once Overnight is pre-selected by default on every cold
   launch, `parkUntilMode` is true at rest 100% of the time, and this old small pill ("Until Thu 9:00 PM"
   + a Clear ✕) will render simultaneously with the new goal-tile dock, duplicating the same "a filter is
   active" information in two different UI languages at once. Fix: gate that row off whenever the
   goal-first ambient dock is visible (i.e., `!fullPaletteMode`). It should reappear in its existing,
   unchanged form only once the user has toggled to full-palette (§2.4) AND set a target via the
   power-user `ParkUntilSheet` (§0.8.9's unchanged path) — its original job, untouched.
2. **Clock-icon conditional visibility in `recenterButtonStack`** — see §2.6. Not mechanically specified
   elsewhere; needed for §0.8.9's "not reachable directly from the goal-first home screen" to actually
   hold.
3. **Search icon insertion point** — §2.6: 2nd button in `recenterButtonStack`, after "Find me," before
   the conditional "Find my car." A reasonable default, not a hard requirement — if the stack starts
   feeling too tall with "Find my car" + Search + clock all visible at once (car parked AND full-palette
   mode, a rare but real combination), moving Search to a standalone top-left circle is the fallback,
   not a redesign.
4. **One bottom dock at a time.** The new ambient goal-first dock (§2.1) and the existing Drive-Mode
   `bottomSafeAreaContent` must never both render — same mutual-exclusion discipline already enforced
   between that file's own `driveModeActive`/`blockSelectModeActive` rows. Gate the new dock on
   `!driveModeActive && !blockSelectModeActive && !spotPlacementActive`, matching
   `recenterButtonStackVisible`'s existing exclusion list.

---

## Summary for the orchestrator

Copy locked in: **Overnight** ("Won't need to move it," `moon.stars.fill`) / **A Few Hours** ("No meter,
no cost," `hourglass`) / **Park & Forget** ("Go days without moving it," `parkingsign.circle.fill`) —
"Free" dropped from both ambiguous primary labels per §0, with the actual promise stated plainly in each
sub-label instead. Full-palette toggle: **"Show all parking rules"** (`paintpalette.fill`), flipping to
"Back to goal picker" once active. Secondary escalation: **"Start Driving"** (`location.north.circle
.fill`), Kevin's own wording kept. Biggest layout call: a horizontal row of three big square-ish tiles
(not stacked full-width rows) as a new, dedicated ambient-only bottom dock, filled-blue-capsule selection
idiom ported from `sweeperDirectionRow`/`zoneChip`, with "Start Driving" demoted one reach above the
tiles and the full-palette toggle smallest/topmost of all — plus a real, concrete integration bug caught
along the way: the legacy `ParkUntilPill` will double up with the new dock unless explicitly suppressed
in goal-first mode (§6.1).

File: `/root/repos/parkmap/docs/design/goal-first-ambient-design.md`
