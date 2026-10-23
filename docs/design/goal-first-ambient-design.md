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

---

## Addendum 2 — 2026-10-21 smoke revisions

**Trigger:** Kevin's flag-on simulator smoke of the shipped build (PRs #133/#134). Two screenshots, two
revision requests. PR #134 already fixed the overlap bug (Report pill / "?" button no longer draw on top
of the goal dock) — but fixing clearance *math* left both floating alone, disconnected from any other
chrome, which reads as broken even though nothing technically overlaps. Separately, the escalated Cruise
session carries a goal filter with zero legible indicator of which goal is active. Both fixes below are
scoped, implementable without new mechanisms, and keep every rule from §0–§6 above intact (5-color
palette untouched, no new confirm steps, flag-off byte-identical).

### A2.1 — Ambient chrome placement: Report pill + "?" button get permanent homes, not a new clearance constant

> **SUPERSEDED IN PART by Addendum 3 (below), 2026-10-23.** Kevin's smoke verdict on the result of this
> section: "too many buttons and icons. It's so messy." Moving Report and "?" into permanent homes was
> structurally right (no more clearance constant) but the homes themselves added to the control count.
> Addendum 3 moves both into a single "More" sheet. The *structural* lesson here (no hand-maintained
> offsets; sit inside a container that tracks its own height) still stands and is reused.

**Root cause, stated plainly so the fix is structural, not another patch:** `communityMapChromeOverlay`
(`ContentView.swift`, the `reportPillButton` + `mapKeyButton` row) is a floating overlay with its own
independently-computed bottom clearance (`communityMapChromeBottomPaddingValue`), living in a different
presentation layer than `GoalSelectorView`'s dock. PR #134 patched that clearance constant to stop
overlapping the dock. That's the same bug class as the original overlap, one level up: a hand-maintained
offset chasing a sibling layout it has no structural visibility into. Any future change to the dock's
height (Dynamic Type growth, a 4th goal tile someday, the empty-map guard banner appearing/disappearing)
can desync it again. **The fix is to stop computing a clearance number for this chrome at all** — give
each piece a real, permanent position inside layout containers that already track their own height.

**Decision — split the two pieces, because they're not the same kind of control:**

1. **"?" map-key button → becomes the last circle in `recenterButtonStack`** (top-right rail), not a
   floating bottom element at all. It is already a 44×44pt `.regularMaterial` circle — the exact same
   family as every other button in that stack — so this is a true move, not a redesign. Rationale: a
   "what do the colors mean" lookup is low-frequency and has nothing to do with the bottom action dock;
   Kevin's own instinct ("join the triple ribbon on the right") is correct. Order: Find me → Search →
   Find my car (if parked) → clock (full-palette only, §2.6) → **"?" (new, last)**. Same
   `Image(systemName:)`/`.font(.system(size: 17, weight: .medium))`/background/foreground treatment as
   the rest of the stack — do not special-case its styling.
   - **Gating:** render in this rail position only when `AppConstants.driveModeDefaultEnabled` is true.
     When the flag is off, "?" stays exactly where it is today (`communityMapChromeOverlay`, bottom-right)
     — zero behavior change, per the flag-off-byte-identical rule.
   - **Full-palette mode:** no special case needed — the rail already renders the clock icon when
     `fullPaletteMode` is true (§2.6) and hides it when false; "?" simply sits below whichever of those
     is currently showing. It never needs to move again.
   - **Watch item, not a blocker:** flag-on + full-palette + a parked car now stacks up to 5 circles
     (Find me, Search, Find my car, clock, "?"). §6 item 3 above already names the fallback for this
     exact "stack getting too tall" case — moving Search to a standalone top-left circle — re-apply that
     fallback here if 5 circles crowds the ASP banner or runs short on smaller phones (SE-class), rather
     than inventing a second fallback.

2. **Report pill → becomes a new top row inside `GoalSelectorView`, sharing a line with the full-palette
   toggle**, not the rail (it's a labeled capsule with real text, "join the triple ribbon" doesn't fit
   it the way it fits "?"). New top-of-dock row, same position reasoning §2.4 already gives the toggle
   ("quietest, farthest from thumb"):
   ```
   HStack {
       reportPillButton   // leading, unchanged component — same Label("Report", systemImage: "flag.fill")
       Spacer()
       fullPaletteToggleRow-content   // trailing, unchanged component
   }
   ```
   placed as the **first** row in `GoalSelectorView`'s `VStack(spacing: 10)`, i.e. above today's
   `fullPaletteToggleRow` (which keeps its own trailing alignment, now just sharing a line with Report
   instead of occupying a lone `HStack { Spacer(); toggle }` row). Both controls keep their existing
   sizes untouched (Report: `.frame(minHeight: 48)`; toggle: `.frame(minHeight: 44)`) — only their
   container changes.
   - **Why this kills the whole bug class:** Report is now a true sibling in the same `VStack` the dock
     already lays out top-to-bottom. It moves up/down with the dock's actual rendered height for free —
     Dynamic Type growth, the empty-map guard banner appearing, or the goal-tile row hiding in
     full-palette mode all just push or pull this row the normal SwiftUI way. No clearance constant to
     maintain, so no clearance constant to go stale.
   - **Full-palette mode, answered directly:** does chrome "drop down"? Yes, automatically — in
     full-palette, `goalTileRow` (§2.4) is hidden, so the dock is shorter, and the Report/toggle row
     (now its topmost row) sits that much closer to the bottom of the screen. This is exactly the
     behavior Kevin's question was checking for, and it falls out of the VStack for free once Report is
     inside it.
   - **Flag-off:** `GoalSelectorView` never mounts when `AppConstants.driveModeDefaultEnabled` is false
     (`goalSelectorDockVisible` already requires the flag) — so Report never leaves
     `communityMapChromeOverlay`'s current bottom-left position in a flag-off build. Byte-identical,
     same guarantee as item 1.
   - **`communityMapChromeOverlay` update required:** its render condition needs a third state, not just
     on/off — suppress **both** `reportPillButton` and `mapKeyButton` from the floating overlay entirely
     whenever `AppConstants.driveModeDefaultEnabled && goalSelectorDockVisible(...)` is true (reuse the
     same boolean `bottomSafeAreaContent` already computes as `goalDockVisible` — don't compute a second
     one). Outside that condition (flag off, or any of `driveModeActive`/`blockSelectModeActive`/
     `spotPlacementActive`/a sheet being presented), `communityMapChromeOverlay` renders exactly as it
     does today, unchanged — this is additive, not a rewrite of that function's existing gates.
   - **Accessibility:** no label changes — `reportPillButton`'s existing `accessibilityLabel`/`Hint` and
     the toggle's existing label both carry over untouched; only their visual container moves.

**Net result Kevin should see on next smoke:** at 1:13 AM on the ambient screen, the top-right rail now
reads "recenter / search / ? " as one coherent group (exactly his own suggestion), and the Report pill
sits docked to the top edge of the bottom cluster, paired with the palette toggle — nothing floats alone
in the dead middle of the map anymore, and nothing needed a new magic-number offset to get there.

### A2.2 — Active-goal legibility in escalated Cruise: name the goal, don't just show its target date

**Diagnosis:** today's `ParkUntilPill` in `bottomSafeAreaContent` (row 3, directly above
`DriveModeBottomCard`, directly below `driveActionRow`'s Report/Park Here pair) renders the same generic
"● Until Fri 12:00 AM" + clear ✕ regardless of *why* that target exists — whether it came from a goal
tap on the ambient screen or a manual pick in the power-user `ParkUntilSheet`. Once Overnight defaults
on every cold launch, that generic pill is now the **only** on-screen evidence a goal filter is active
during the one posture (Cruise, windshield distance, glance-only) where legibility matters most.

**Decision — upgrade the content of this exact slot; do not add a new location.** The position is
already correct and already proven collision-free in Kevin's own screenshot (driveActionRow above it,
DriveModeBottomCard below it, both rendering cleanly) — the fix belongs entirely in *what* renders
there, not *where*. Inventing a new top-of-screen banner would introduce real collision risk against
the "End" pill, the ASP banner, and (per A2.3 below) the system compass; reusing the proven slot
introduces none.

**New rendering rule for that slot**, in `ContentView`'s existing `if parkUntilMode, let target =
parkUntilTarget, !goalTilesVisible { ParkUntilPill(...) }` call site:

- Add one piece of context the pill needs: whether the active target came from a goal. Compute
  `let activeGoal: ParkingGoal? = (AppConstants.driveModeDefaultEnabled && !fullPaletteMode) ?
  selectedGoal : nil` once per render (same shape as the existing `goalTilesVisible`/`goalDockVisible`
  booleans — this is a third, narrower read of the identical flag+mode state, not new state).
- Pass it into `ParkUntilPill` as a new optional parameter, e.g. `ParkUntilPill(targetDate: target,
  activeGoal: activeGoal) { clearParkUntilFilter() }`.
- **When `activeGoal` is non-nil** (the Cruise-with-a-goal case, Kevin's shot 2), render the named
  variant:

  | Goal | Icon | Short name | Trailing clause |
  |---|---|---|---|
  | `.freeOvernight` | `moon.stars.fill` | "Overnight" | the existing "Good through <day>" formatter (§3.1) — e.g. "Overnight · Good through tomorrow" |
  | `.freeFewHours` | `hourglass` | "A Few Hours" | reuse `ParkUntilPill`'s own existing clock-time formatter unchanged — e.g. "A Few Hours · until 2:45 AM" |
  | `.parkAndForget` | `parkingsign.circle.fill` | "Park & Forget" | `ParkingGoals.goodThroughLabel(...)`'s resolved ladder-rung date — e.g. "Park & Forget · Good through Thu" |

  One line: `[icon] "<Short name> · <trailing clause>"`, `.font(.subheadline.weight(.semibold))` — a
  deliberate step up from whatever the pill's current caption-weight text is, because this is now
  identity information ("which goal is live"), not just a date, and needs to clear the same
  glance-at-a-stoplight legibility bar the rest of Cruise's chrome holds itself to. **No new color** —
  background/material stays exactly what it is today. Per the sacred 5-color palette, green/orange/red
  stay reserved for curb meaning only; differentiating goals by icon + text (not color) keeps this pill
  firmly in the "text is the truth layer" lane §3.1 already establishes, and avoids any reading of "this
  pill's color means something about my parking legality."
  - Formatter reuse note: do not write a fourth date formatter. Overnight/Park & Forget both already
    have `ParkingGoals.goodThroughLabel` (§3.1, already shipped); Few Hours already has whatever clock-
    time string `ParkUntilPill` renders today for a same-day target — call it, don't duplicate it.
- **When `activeGoal` is nil** (flag off, or `fullPaletteMode == true` with a target set via the
  power-user `ParkUntilSheet`) — render **exactly today's pill, unchanged**, generic "● Until <date/time>"
  + clear ✕. This is the existing, correct behavior for the power-user path and must not change.
- **Dismiss/clear semantics — keep, don't gate.** The ✕ stays wired to the same `clearParkUntilFilter()`
  call, ungated, no confirm step, in both the named and generic variants. Rationale: every other control
  on this screen (goal tiles, the full-palette toggle) is already a no-confirm, instantly-reversible tap
  (AC-22/AC-27) — adding a confirm here specifically would be the one inconsistent control on the whole
  surface, for an action that's trivially undoable (tap a goal tile again). Accessibility label should
  say what it now clears, e.g. "Overnight goal active, good through tomorrow. Clears the filter and
  shows all parking rules." so VoiceOver users get the same "this is a goal, not a raw time" context
  sighted users get from the icon/short-name.
- **Collision check, explicit:** this pill's row does not move — same `bottomSafeAreaContent` slot,
  same VStack position relative to `driveActionRow` (Report/Park Here, directly above) and
  `DriveModeBottomCard` (directly below). Kevin's own screenshot already shows this slot rendering
  cleanly between those two neighbors; upgrading its content only (never its size class, never its
  position) carries that same proof forward rather than reopening it.

**Net result Kevin should see on next smoke:** the pill that used to read only "● Until Fri 12:00 AM"
now reads "🌙 Overnight · Good through tomorrow" (moon icon, not literal emoji — SF Symbol
`moon.stars.fill`) in the exact same slot, same size class bump only, same ✕ behavior — answering "what
rule is this screen enforcing right now" without requiring a trip back to the ambient screen to check.

### A2.3 — Compass visibility during rotation (recommendation only, one paragraph)

What Kevin saw in shot 2 (the system compass transiently visible during a turn, despite PR #132's "hide
the compass" work) is very likely **Apple's own documented default**, not a regression: `MKCompassButton`
defaults to `visibilityPriority = .adaptive`, which is explicitly designed to stay hidden while the map
sits at its resting heading and fade in only while the map is actively rotating away from north, then
fade back out once it settles — the compass is *most* useful exactly during a turn, and Apple's adaptive
behavior surfaces it only then. If PR #132's fix set `mapView.showsCompass = false` globally, the system
should never add a compass at all, including mid-rotation, and this would be a real regression worth
filing. But if the fix instead hid a custom-positioned compass view while leaving MapKit's own default
`.adaptive` system compass button untouched, the rotation-triggered appearance is MapKit doing exactly
what `.adaptive` is documented to do, independent of app code. **Recommendation:** verify which of the
two PR #132 actually did; if WePark's intent is "never show a compass, full stop" (reasonable here, since
the drive chevron already communicates heading and a second indicator popping in mid-turn is redundant,
unpredictable chrome exactly when "minimal chrome while driving" matters most), the correct fix is
`compassButton.visibilityPriority = .hidden` (hard-hidden) rather than relying on `showsCompass`/`.adaptive`
defaults, which are built to do precisely what was observed.

---

**Summary of this addendum for the orchestrator:** (1) "?" map-key button moves permanently into the
top-right `recenterButtonStack` as its last circle, flag-on only, byte-identical flag-off; (2) the Report
pill moves permanently into a new top row of `GoalSelectorView`, paired on one line with the existing
full-palette toggle, so both ride the dock's own VStack height instead of a hand-maintained clearance
constant — this also answers "what happens in full-palette mode" for free (the row just sits closer to
the bottom once the tile row hides); (3) in escalated Cruise, the existing `ParkUntilPill` slot (position
unchanged, already collision-proven against Report/Park-Here above and the bottom card below) gets a
named-goal content upgrade — icon + short name + "Good through <day>"/time clause — only when the active
filter came from a goal tap, falling back to today's generic pill otherwise, same ✕-clears-instantly
semantics; (4) the rotating-compass sighting is flagged as likely correct `.adaptive` MapKit behavior,
not a PR #132 regression, with a one-line fix (`visibilityPriority = .hidden`) if WePark wants it
suppressed unconditionally.

File: `/root/repos/parkmap/docs/design/goal-first-ambient-design.md`

---

## Addendum 3 — minimal ambient screen

**Date:** 2026-10-23. **Scope:** flag-on only (`AppConstants.driveModeDefaultEnabled == true`). Flag-off
is byte-identical: nothing below mounts, and `communityMapChromeOverlay`, `recenterButtonStack`, and the
Browse sheet render exactly as they do today.

**Locked input (Kevin, 2026-10-23): Option A.** The app opens with the *driving look* (tilted, zoomed in,
muted map style) on the cheap location posture (coarse GPS, no wake lock). Full drive engages on sustained
motion or one tap. Options B and C are one-line notes in A3.6 only.

**Trigger:** Kevin, after seeing the Addendum 2 screen in the simulator: *"too many buttons and icons.
It's so messy."* His standing bar: *"buttons need to be huge and obvious... anyone who boots it up should
get it."* Both are right, and this is on me: Addendum 2 fixed where each control sat but never asked
whether each control needed to sit on the main surface at all. Count at the Addendum 2 screen: recenter,
search, find-my-car, "?", Report, "Show all parking rules", Start Driving, three goal tiles = **10
controls**, plus the ASP banner. A first-time user cannot rank ten things in five seconds.

**Thesis (one sentence):** the main surface answers one question, "what do you want from parking?", so
only the answer buttons, one way to go somewhere, one door to everything else, and one "go" button may
live there. Everything else is at most two taps away and nothing is lost.

**What this supersedes:** A2.1 in full (the Report pill's dock row and the "?" rail circle; the
`communityMapChromeOverlay` suppression stays, now because both live in More). A2.2 (named-goal pill in
Cruise) and A2.3 (compass) stand unchanged. §0–§6 stand except where this addendum names a change (§2.1
dock structure, §2.2 sizes, §2.3 Start Driving size, §2.4 toggle location, §2.6 rail contents).

### A3.1 — The minimum always-visible set

**Six controls, down from ten:**

| # | Control | Where | Why it earns a place on the main surface |
|---|---|---|---|
| 1-3 | Three goal tiles (Overnight / A Few Hours / Park & Forget) | Bottom dock | They ARE the product's first question. Non-negotiable per Kevin's rulings. |
| 4 | Start Driving | Bottom dock, above tiles | Under Option A it is the one obvious "go live" tap. See A3.6. |
| 5 | Search | Top-right rail | Job B (go somewhere, then park) needs a one-tap door. Burying it in More makes Job B two taps (§0.4a). |
| 6 | More | Top-right rail | The single door to everything else. |
| (+) | Recenter | Top-right rail, **only after the user pans away** | Appears when needed, not before. Not counted at launch. |
| (status) | ASP banner | Top, only on suspension days | Information, not a control. Unchanged. |

**Removed from the main surface (all still reachable, see A3.5):** the Report pill, the "?" key button,
"Show all parking rules", and the Find-my-car circle. The resting launch screen shows **6 tappable
things**.

### A3.2 — The rail: two circles, optional third

Top-right, trailing margin 16pt, below the ASP banner (or top safe area + 8pt when no banner). Vertical
`VStack(spacing: 12)`. Each button is a **56 x 56pt** circle (up from 44pt; Kevin's bigger-targets
preference, comfortably above HIG's 44pt floor), `.regularMaterial` fill, `.foregroundStyle(.primary)`,
icon `.font(.title3.weight(.semibold))` (scales with Dynamic Type; circle stays 56pt; cap the icon with
`.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` on the rail only).

Order, top to bottom, fixed so nothing shifts when another appears:

1. **Search** — `magnifyingglass`. `accessibilityLabel("Search")`, hint "Find a street or place". Presents
   `.browseNav` at `.medium` (unchanged from §2.6).
2. **More** — `ellipsis`. `accessibilityLabel("More")`. Presents the More sheet (A3.4).
3. **Recenter** — `location` (`location.fill` while the map is following the user). `accessibilityLabel(
   "Show my location")`. **Conditional:** render only when (a) location is authorized and the user's dot is
   outside the central 50% of the visible map, or (b) authorization is `.notDetermined` (it is the route to
   the permission prompt). Last in the stack so its appearance never moves Search or More; `.transition(
   .opacity)`; no haptic.
   - **Engineer fallback, if the off-center test is judged too heavy for this PR:** always render it as the
     third circle. Acceptable, less minimal; the conditional version is the target.

Not on the rail anymore: the old clock icon (moves to More, full-palette only), "?" (More), Find my car
(More, plus the car marker). The rail never exceeds three circles in any mode.

### A3.3 — The bottom dock

The dock keeps §2.1's structure with two rows deleted and sizes raised. Top to bottom:

```
VStack(spacing: 10) {
    if showsEmptyMapGuard { emptyMapGuardBanner }  // unchanged, contextual
    startDrivingRow       // see A3.6
    goalTileRow           // goal-first mode
    // full-palette mode adds backToGoalsRow below startDrivingRow and hides goalTileRow
}
.padding(.horizontal, 16)
.padding(.bottom, 8)
```

- **Deleted from the dock:** the Addendum 2 Report + full-palette toggle row.
- **Goal tiles, size bump (supersedes §2.2 sizes only; colors, selection idiom, copy, a11y unchanged):**
  `minHeight: 128` (was 112). Icon `.font(.title)` (was `.title2`). Primary `.headline` bold, up to 2 lines.
  **Sub-label `.footnote`, up to 3 lines (was `.caption`, 12pt, too small for a glance at a stoplight).**
  At accessibility Dynamic Type sizes (`dynamicTypeSize.isAccessibilitySize`) the row switches from `HStack`
  to a vertical `VStack` of three full-width tiles (icon leading, text trailing) so labels never truncate.
- **Selection haptic (the one haptic on this screen):** `.sensoryFeedback(.selection, trigger:
  selectedGoal)`. Picking a goal is a mode change a driver may make without looking; a light tick confirms
  it. No haptic on Start Driving, Search, or More.
- **Full-palette mode (reached from More, A3.4).** Tiles hide. So the user is never stranded, the dock adds
  a second full-width row **under** Start Driving: `Label("Pick a parking goal", systemImage:
  "rectangle.split.3x1.fill")`, `.buttonStyle(.borderedProminent)`, `.tint(.blue)`, `minHeight: 56`,
  `.font(.headline)`. Tap re-applies the last-selected goal and brings the tiles back. Accessibility label
  "Pick a parking goal", hint "Go back to the three parking goals". This replaces the old reverse-direction
  toggle label (§2.4). The clock power-user path lives in More (A3.4 row 5).
- `ParkUntilPill` suppression (§6.1) and one-dock-at-a-time (§6.4) are unchanged.

### A3.4 — The More sheet

Opened by the rail's `ellipsis` button. Add one `ActiveSheet` case (e.g. `.moreMenu`); selecting a row
**swaps** `activeSheet` to the destination rather than stacking sheets.

**Why a sheet and not a SwiftUI `Menu`:** system `Menu` rows are about 44pt with no room for a one-line
explanation. Kevin wants roomy targets, and Report needs a sentence of context to be discoverable. A
medium-detent sheet gives 64pt rows with subtitles and is still a plain system `List` (native feel, Dark
Mode and Dynamic Type for free).

Structure: `NavigationStack { List { ... } .listStyle(.insetGrouped) }`, inline title **"More"**, trailing
toolbar **Done**. `.presentationDetents([.medium])`, `.presentationDragIndicator(.visible)`. Each row:
`minHeight: 64`, leading icon in a 44pt rounded square (`.blue.opacity(0.15)` fill, `.blue` symbol,
`.title3`), title `.headline`, subtitle `.subheadline` `.secondary`, whole row tappable. **All icons blue**;
no green, orange, or red here (those colors belong to curb meaning only).

Rows, in priority order:

| # | Title | Subtitle | SF Symbol | Action | Shown when |
|---|---|---|---|---|---|
| 1 | **Report** | Tell neighbors what you see | `flag.fill` | `activeSheet = .report` (same destination the old pill used) | `AppConstants.communityEnabled` |
| 2 | **What the colors mean** | Green, red, and the rest | `questionmark.circle.fill` | Opens the existing map-key sheet (the old "?" destination) | always |
| 3 | **Show all parking rules** | See every kind of rule, not just one goal | `paintpalette.fill` | A `Toggle` row bound to `fullPaletteMode` | always |
| 4 | **Find my car** | Show where you parked | `car.fill` | The old Find-my-car action | only when a car is parked |
| 5 | **Park until a set time** | Pick your own time | `clock.fill` | Opens existing `ParkUntilSheet` | only when `fullPaletteMode` |

The toggle row dismisses the sheet after flipping so the user sees the result at once. Accessibility: each
row is one element, label "<Title>, <subtitle>"; the toggle uses system `Toggle` semantics.

**Report discoverability, answered directly.** Report is row 1 and has the only verb-plus-reason subtitle;
More is a universally understood door. Two backstops so it is not a hidden feature: (1) the car marker and
block-detail sheet stay the contextual paths. **@ios-engineer to confirm the block-detail sheet already
offers a Report action for the tapped block, and if not, add it; "report this block" is the most natural
moment for the action** (verify-item, not assumed). (2) No coach mark or nag (§0.1 "Must NOT"). **Escape
hatch if Kevin wants Report visible without opening anything:** put it on the rail in place of Search and
move Search to the first row of More. That costs Job B one tap, which is why it is not the default.

### A3.5 — Where every displaced control went

| Old control (Addendum 2) | New home | Taps from launch |
|---|---|---|
| Report pill | More, row 1 (plus block-detail sheet, verify per A3.4) | 2 |
| "?" key | More, row 2 | 2 |
| Show all parking rules | More, row 3 (toggle); way back is the dock's "Pick a parking goal" | 2 (1 to return) |
| Find my car circle | More, row 4 (only when parked); the car marker on the map is also tappable | 2 (or 1 via marker) |
| Clock / Park Until | More, row 5 (full-palette only) | 3 |
| Recenter | Rail, appears only after panning away | 0 (or 1) |
| Search | Rail, always | 1 |
| Start Driving | Dock, always (A3.6) | 1 |

Palette check: no green, orange, or red in any new chrome. Selected tile stays blue; More icons are blue;
"Pick a parking goal" is blue.

### A3.6 — Start Driving and the opening look under Option A (chosen)

**A3.6.1 What the user sees at launch (the "driving look").**
- **Camera:** tilted and zoomed in using the *same pitch and distance constants as the escalated Cruise
  camera* (reuse them; do not invent new numbers), with **heading fixed at 0 (north-up)**. Heading-up
  rotation needs a GPS course, which coarse/one-shot location does not give; rotating on a guessed heading
  would turn the map the wrong way. North-up until motion is the honest behavior.
- **Style:** `.mutedStandard`, the same muted style Cruise uses, which also makes the green/red goal answer
  pop. Palette untouched.
- **Marker:** the standard blue user dot, **not the heading chevron**. A chevron pointing the wrong way at
  launch is worse than none. The chevron appears only when full drive engages and a real course exists.
  Suppress the large accuracy ring in this posture (a 100m ring at zoomed-in scale swallows several blocks
  and looks broken).
- **Accuracy guard:** zoom to the Cruise distance only if the first fix has `horizontalAccuracy <= 65m`;
  otherwise open one step wider (still tilted, still muted) and tighten when a better fix arrives. At
  100m error a fully zoomed-in view would visibly put the dot on the wrong block, which for a parking app
  is a trust problem.
- **Gestures:** pan, pinch, and tap-a-block keep working (the couch user is still served). If the user pans
  away, Recenter appears (A3.2).
- **Battery invariants (restating spec §0.2, now load-bearing for A):** at launch NO continuous location
  updates, NO `isIdleTimerDisabled`, NO voice. The look is purely camera + style; `driveModeActive` stays
  `false`.

**A3.6.2 Start Driving: decision: keep it as one obvious control in the dock; do NOT fold it into the
rail.** Reasons: Option A's whole promise is "one tap engages full drive," so that tap must be unmissable;
a 56pt circle with a glyph is the kind of ambiguous icon Kevin just rejected, and the rail is for
secondary tools. It stays directly above the tiles (the extra-reach rationale in §2.1 still holds, since
engaging has real side effects).
- Style: full-width `.buttonStyle(.bordered)`, `.tint(.blue)`, blue label, `minHeight: 64` (up from 48),
  `.font(.headline)`, `Label("Start Driving", systemImage: "location.north.circle.fill")`. Bordered, not
  prominent, so it never out-shouts the filled-blue selected tile; size and position carry the emphasis.
- **Caption (conditional, honest):** a second line inside the bar, `.footnote` `.secondary`, **"Starts on
  its own when you move"**, shown only while `cruiseAutoEngageEnabled == true`. Before the motion service
  ships, show no caption and use `minHeight: 56`; the copy must never promise behavior that does not exist.
- Tap: existing `enterCruiseMode()` including the §0.2 authorization fix (route through
  `requestAndFetchLocation()` first when `.notDetermined`).

**A3.6.3 Engagement and the handoff.** On tap, or on sustained motion once `cruiseAutoEngageEnabled` is
live (thresholds are spec §0.5's problem): the camera swings to heading-up as the first course arrives,
the dot becomes the chevron, voice and wake lock start, and the **ambient dock is replaced** by Cruise's
own bottom stack (one dock at a time, §6.4). The Start Driving bar therefore disappears on engage rather
than turning into something else; "End" returns to this exact launch look. The goal filter carries over
unchanged, and A2.2's named-goal pill is what shows it in Cruise.

**A3.6.4 Phasing.** The tap path and the driving look can ship before the motion service exists (A without
the caption). Motion auto-engage remains the separate dark flag from spec §0.5.

**One-line notes on the other options (not chosen):**
- **B (full drive at launch):** Start Driving would be deleted, but it forces the goal tiles into the drive
  session and breaks the rest-state battery invariant (spec §0.2); not recommended.
- **C (calm map + auto-engage):** Start Driving would be removed once `cruiseAutoEngageEnabled` is on, with
  a manual "Start Driving" row added to More; the cleanest screen, and a one-step move later from A if
  Kevin wants it.

### A3.7 — Wireframes (393 x 852 pt iPhone, flag-on)

**MAIN: Option A launch screen, Overnight selected (6 controls).** Tilted, zoomed in, muted; north-up; blue
dot, no chevron.

```
+--------------------------------------+
| ASP banner (only on suspension days) |  status, not a control
|                               ( Q )  |  Search     magnifyingglass   56pt
|                               ( … )  |  More       ellipsis          56pt
|                               ( > )  |  Recenter   only after panning away
|        far blocks, small, muted      |
|      =====   ====   =====   ====     |  tilted map, muted style
|    ======   =====   ======  =====    |  green = yes, red = no
|   =======  ======   =======  ====    |
|  ========  =======  ========  ===    |  blocks grow toward the viewer
|              (o)   you               |  blue dot (no ring, no chevron)
|                                      |
| +----------------------------------+ |
| | > Start Driving                  | |  bordered blue, 64pt, full width
| |   Starts on its own when you move| |  caption only if auto-engage is live
| +----------------------------------+ |
| +-----------+ +----------+ +--------+ |
| | moon.stars| | hourglass| | P sign | |  icons .title
| | OVERNIGHT | | A FEW    | | PARK & | |  headline bold
| | (filled   | | HOURS    | | FORGET | |
| |  blue)    | |  gray    | |  gray  | |
| | Won't need| | No meter,| | Go days| |  footnote, up to 3 lines
| | to move it| | no cost  | | without| |
| |           | |          | | moving | |
| +-----------+ +----------+ +--------+ |  128pt min height
+--------------------------------------+
```

**After Start Driving or sustained motion (existing Cruise, shown for contrast only; the ambient dock is
gone).** Heading-up, chevron, voice; named-goal pill per A2.2.

```
+--------------------------------------+
| (End)                                |
|        heading-up map, chevron       |
|        [moon] Overnight · Good       |
|        through tomorrow   (x)        |  A2.2 pill
|        existing Cruise bottom card   |
+--------------------------------------+
```

**Full-palette mode (More, "Show all parking rules" on).** Tiles replaced by one row; map shows five
colors; the look (tilt, muted) is unchanged.

```
|                               ( Q )  |
|                               ( … )  |
|        tilted map, five colors       |
| +----------------------------------+ |
| | > Start Driving                  | |  bordered blue
| +----------------------------------+ |
| +----------------------------------+ |
| | [] Pick a parking goal           | |  filled blue, 56pt
| +----------------------------------+ |
```

**The More sheet (medium detent).**

```
+--------------------------------------+
|              ----- (drag)            |
|  More                          Done  |
|  +--------------------------------+  |
|  | [flag]  Report                 |  |  64pt rows
|  |         Tell neighbors what    |  |
|  |         you see                |  |
|  | [ ? ]   What the colors mean   |  |
|  |         Green, red, and the    |  |
|  |         rest                   |  |
|  | [pal]   Show all parking rules |  |
|  |         See every kind of rule (o) |  toggle
|  | [car]   Find my car            |  |  only when parked
|  |         Show where you parked  |  |
|  +--------------------------------+  |
+--------------------------------------+
```

### A3.8 — Five-second check, acceptance, and engineer flags

**Re-run of the §5 walkthrough on the new screen.** 0-1s the eye lands on the three tiles (nothing else
competes: two small circles top-right, one bordered bar). 1-2s filled blue vs gray says "one is chosen."
2-3s "Overnight, won't need to move it" lands the value. 3-5s the other two tiles read as alternatives and
the bar reads as "go drive." The tilted, muted map says "this is the driving screen" before any text is
read. Zero unexplained icons, which is the failure the Addendum 2 screen had.

**Acceptance checks for @qa-verifier:**
1. Flag-on cold launch shows exactly: Search, More, Start Driving, three tiles (Recenter absent while
   centered on the user; ASP banner only on suspension days). Count controls in the screenshot.
2. Launch camera is tilted and zoomed, heading 0, muted style; user marker is the dot (no chevron);
   `driveModeActive == false`, no continuous location updates, `isIdleTimerDisabled == false`.
3. With a poor first fix (accuracy worse than 65m) the launch camera is one step wider, then tightens.
4. Start Driving tap engages full drive; with the dark flag on, sustained motion does too; the ambient dock
   disappears on engage and End returns to the launch look.
5. Report, key, palette toggle, Find my car reachable from More in two taps; Report works from More with
   the same result as the old pill.
6. Toggling full-palette shows "Pick a parking goal" and it restores the tiles; no state lacks a way home.
7. No tap target under 44pt; rail circles 56pt; tiles at least 128pt; Start Driving at least 56pt.
8. Largest Dynamic Type (AX5): tiles reflow to a vertical stack, no clipped text, nothing overlaps the rail.
9. Flag-off screenshot diff against the pre-Addendum-3 build: identical.
10. No green, orange, or red used by any new chrome.

**Flags for @ios-engineer:**
1. `communityMapChromeOverlay`'s suppression rule from A2.1 stays (hide Report and "?" while the goal dock
   is visible); it is now correct because both live in More.
2. Delete (flag-on path only) the Report/toggle top row from `GoalSelectorView` and the "?" circle from
   `recenterButtonStack`; flag-off branches stay exactly as they are.
3. Add `.moreMenu` to `ActiveSheet`; row taps swap `activeSheet`, never stack. Dismissals must return to the
   rest state via `driveModeDefaultRestStateSheet()` (spec §0.4 note).
4. The driving-look camera is camera + style only; do not set `driveModeActive`. Reuse Cruise's pitch and
   distance constants, set heading 0, and keep the #31 camera-mutation invariant called out in the PR.
5. Recenter's off-center test belongs in a small pure function with a unit test, per this project's habit.
6. Per the project's Swift compile-failure classes: qualify `WePark.Category` in test targets.

### 💡 Out of scope (future, captured not requested)

- A tiny inline green/red legend on the ambient screen would make "What the colors mean" nearly
  unnecessary, since goal mode only ever shows two colors. Revisit after the smoke.
- Remember the last goal across launches (already deferred, spec §0.8.8 / §6).

**Summary of this addendum for the orchestrator:** Option A is the primary spec: launch looks like driving
(tilted, zoomed, muted, north-up, blue dot instead of a guessed chevron) on coarse GPS with no wake lock,
and Start Driving stays as one obvious 64pt bordered bar above the tiles (not folded into the rail),
engaging full drive on tap or sustained motion, with its "Starts on its own when you move" caption only once
auto-engage exists. Six visible controls instead of ten (Search, More, Start Driving, three huge tiles;
Recenter only after a pan); Report, "?", the palette toggle, Find my car, and the Park Until clock all live
in one More sheet with 64pt rows and Report first, and full-palette mode keeps a "Pick a parking goal"
button so nobody is stranded.

File: `/root/repos/parkmap/docs/design/goal-first-ambient-design.md`
