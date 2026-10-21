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
