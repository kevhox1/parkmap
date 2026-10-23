# Long-press (and pill) as the universal "plant anything" entry — execution spec

**Supersedes:** `docs/open-items.md` #118 (tap-to-reposition, still `MERGE-PENDING-MAC-GATE`,
**not yet merged** — see §6) and #22 (the original "report flow: tap-to-place" spec,
`docs/report-tap-to-place-spec.md`, which #118 implemented). Both files are kept for history,
not deleted. **Does NOT supersede** #121 (curb-snap-on-display) — orthogonal, independent,
should proceed on its own schedule. **Does fold in / retire** #17b's target (the legacy
three-button `confirmationDialog` that #17b was patching is deleted outright by this spec, not
patched further).

**Amended 2026-10-23:** see "Amendment — fixed-center pin with live curb snap" at the end of this
file (placement mode + curb snap inserted before the chooser, flag-gated; supersession table in A.8).

**Status:** spec-first, not started. Touches the single most-used, unflagged core interaction
(long-press-to-park) — treat with the same elevated care `docs/report-tap-to-place-spec.md`
used, not as a routine feature add.

**Session estimate:** ~2.5–3 engineering sessions (serialized, one engineer — same
`ContentView.swift`/`ReportSheet.swift` file-contention reason the #22 spec gave) + 1 designer
pass (parallel, non-blocking) + 1 elevated-rigor QA pass over the core parking path. Call it
3–4 sessions wall-clock given the QA/Mac-gate tail.

---

## 0. Open decisions (read first — recommendations attached, nothing blocks starting on the rest)

| # | Decision | Recommendation |
|---|---|---|
| 1 | Does this replace #118/#22 entirely, or coexist? | **Replace entirely.** #118 is still sitting unmerged (`MERGE-PENDING-MAC-GATE`) — this is the cheapest possible moment to cut it: zero Mac-compile time sunk, zero production exposure. Recommend Kevin skip #118's pending Mac gate and let it die on its branch. |
| 2 | Does #121 (curb-snap-on-display) ride along or stay independent? | **Stays fully independent.** It's a pure rendering fix (pin position on the map, not entry UX) and has nothing to do with how a report gets *created*. Let it merge on its own Mac-gate schedule, before/after/during this spec — no sequencing dependency either way. |
| 3 | Does "Street closure" (multi-block select) join the unified chooser as a tile? | **Yes, as a handoff tile** — identical shape to today (tap → dismiss chooser → enter block-select mode). No interaction-model change; closures are inherently multi-block and don't fit a single-point placement model, so don't force them into one. |
| 4 | Does "Spot open" become one-tap-done when entered via long-press (since placement already happened)? | **Yes for long-press entry; no change for pill entry (for now).** Long-press already IS the curb-precise tap `SpotPlacementView` asks for separately today — making the user tap twice is the old world's constraint, not a requirement. Pill entry is GPS-seeded (not curb-precise), so it still needs its own tap-the-curb refinement step, unchanged. This is a real behavior change to an already-shipped flow (Community 2.0 Phase 2b) — flagging it explicitly rather than burying it; confirm before an engineer starts. |
| 5 | Flag-off chooser: full chooser UI with one tile, or collapse straight to a park-confirm card? | **Collapse.** When `communityEnabled == false`, exactly one tile ever applies ("Park my car here") — showing a one-item chooser is pointless ceremony. Flag-off keeps today's single-purpose confirm card (`LongPressParkConfirmCard`'s copy/shape), just reached through the same code path as the flag-on chooser rather than a separate dialog. Zero visible change for flag-off users. |
| 6 | Ship as one PR, or stage the Park-only plumbing first? | **Stage Park-only first, as its own small PR.** It's pure plumbing (no new tiles, no new copy) against the highest-stakes flow in the app. Landing it alone makes a regression trivially bisectable before the lower-stakes community tiles pile on top in PR 2. Not a feature flag — a sequencing choice. See §4. |

---

## 1. Problem & user story

**Kevin's framing (2026-10-02):** *"Should long hold be how we plant anything — including
parking but also parking enforcement, agents, block closures etc? It seems like the most
straightforward way, especially given we are having so much trouble with the relocation and
selecting map after we hit enforcement."*

**Today's shape is split across two unrelated mechanisms that happen to look similar:**

- **Resting long-press, flag-on:** `handleLongPress(at:)` (`ContentView.swift:4266`) captures
  the coordinate and shows `LongPressParkConfirmCard` — **Park only.** There is currently no way
  to report enforcement/sweeper/spot-open/closure by long-pressing a precise point while flag-on.
  That capability existed for flag-off users (see below) and was silently dropped when S13a
  slimmed the card to park-only (`ContentView.swift:4186-4188`: *"reporting has its own dedicated
  entry now, the S13a Report pill + grid"*) — the pill uses **current GPS**, not the point you're
  pointing at.
- **Resting long-press, flag-off:** the legacy `.confirmationDialog` (`ContentView.swift:1116-1190`)
  still has all three actions, and its "Report enforcement or sweeper" button already does
  **exactly** what Kevin is now asking for universally: it resolves candidates from
  `pendingLongPressCoord` — the literal long-press point — and opens
  `ActiveSheet.reportPin(coord: coord, ...)` **already seeded**, before any sheet exists
  (`ContentView.swift:1131-1167`). This is proof the "plant-then-choose" shape already works
  cleanly in this codebase. It just isn't universal, and it isn't available to flag-on users.
- **Report pill (flag-on, both driving and resting):** always GPS/map-center seeded
  (`handleReportPillTap`, `ContentView.swift:2356-2369`) — one tap to the grid, but you can't
  correct *where* without leaving the pill's coordinate source entirely.
- **PR #118's bolt-on "Reposition":** tries to let a user correct the pill's coordinate **from
  inside an already-presented `ReportSheet`**, by tapping the map underneath the `.medium`-detent
  sheet. This requires threading a side-channel binding into the live sheet specifically so
  SwiftUI doesn't tear down `ReportSheet`'s `@State` on a coordinate-keyed `.sheet(item:)` re-fire
  (`docs/report-tap-to-place-spec.md` §3.2, "the state-loss landmine"). QA proved the mechanism
  works (`docs/qa/pr118-tap-to-place.md`) but flagged two real fragility findings (scroll-guard
  gap, transient dual-mode window) — exactly the class of fight Kevin is reacting to: tapping the
  map *through* a presented sheet is inherently fiddly, because the sheet's identity and the
  map's tap target are fighting over the same gesture surface.

**The inversion Kevin is proposing, and why it's structurally simpler, not just a redesign:**
place the point **before** any sheet exists — exactly the flag-off legacy dialog's own pattern,
generalized — then present one "What's here?" chooser whose only job is "which of these N things
did you just point at," anchored to a coordinate that will never move again for the lifetime of
that sheet. There is no reposition control inside the chooser **because there's nothing left to
reposition** — if the point is wrong, the correction path is dismiss-and-redo, not an in-sheet
map tap. This isn't a workaround for the tap-through-a-presented-sheet bug; it removes the
precondition for that bug entirely (there is no map interaction while any sheet is presented,
full stop).

---

## 2. Scope

**In:**
- One universal placement-then-chooser flow, reachable two ways:
  - **Long-press** the map (resting, not driving, not mid-block-select) → precise point.
  - **Tap the Report pill** → current-GPS (or map-center fallback, same chain as today) point.
- One chooser sheet ("What's here?") whose tile set is: **Park my car** (always available,
  not flag-gated) + **Enforcement active** / **Sweeper passed** / **Spot open** / **Street
  closure** (all `communityEnabled`-gated, unchanged copy/icons/colors from today's grid).
- Retiring the legacy three-button `confirmationDialog`, `LongPressParkConfirmCard`, and
  `LongPressPresentation`/`longPressPresentationMode` — one mechanism for both flag states,
  the flag only decides which tiles render.
- Retiring #118's entire reposition machinery (`ReportRepositionUpdate`, `repositionUpdate`,
  `reportRepositionModeActive`, `showsRepositionAffordance`, the reposition `handleMapTap`
  branch) as dead weight.
- The flag-off single-tile collapse (OD-5).
- Spot-open's one-tap-done behavior specifically for long-press entry (OD-4), pending Kevin's
  confirmation.

**Out (explicit follow-ups, not blocking):**
- Extending this to Drive Mode's dedicated arrival-prompt "Park here" flow (TF2-7) — stays its
  own safety-first, no-browsing flow. Driving is not the moment to present a 5-tile menu.
- Pill-sourced Spot-open losing its tap-the-curb refinement step — deferred, see §6.
- Renaming `ReportSheet`/`ReportType`/the file itself to reflect the widened scope — naming
  debt, explicitly accepted rather than bloating this diff (see §3.1).
- #121's curb-snap-on-display — independent, untouched by this spec.
- The designer's exact tile layout (full-width Park row above a 2×2 grid, vs. a 5-cell grid) —
  runs in parallel, doesn't block engineering (§4).

---

## 3. Architecture

### 3.1 Where the chooser lives — reuse `ReportSheet`, don't build a new view

`ReportSheet` already has exactly the machinery this needs: a pure, `Equatable`,
directly-testable tap-routing model (`ReportGridTile` → `ReportGridDestination` via
`destination(forTapping:communityEnabled:candidates:)`, `Views/ReportSheet.swift:1491-1560`) that
already handles "some tiles select a type and continue in-sheet, some tiles hand off and dismiss
the sheet entirely" (`.selectType`, `.streetClosureHandoff`, `.spotPlacementHandoff`). Park is a
third flavor of handoff, not a new concept:

```swift
// Views/ReportSheet.swift — additive, same shape as the two existing handoff cases
enum ReportGridTile: Equatable {
    case parkMyCar          // NEW
    case type(ReportType)
    case streetClosure
    case spotOpen
}

enum ReportGridDestination: Equatable {
    case parkMyCarHandoff   // NEW — dismisses the sheet, caller does the W5 park-pin flow
    case selectType(ReportType, showsConfirmStreet: Bool)
    case streetClosureHandoff
    case spotPlacementHandoff
}
```

**Recommendation: do not rename the Swift type.** `ReportSheet`/`ReportType` keeping their
current names while now also hosting "Park my car" is a small naming inaccuracy, not a
correctness problem — a full rename (`ReportSheet` → something like `WhatsHereSheet`) touches
every call site and test for zero behavior change. Accept the debt; the sheet's user-facing
**title** changes ("What's here?" replacing "Report"), the Swift identifier doesn't. Flag this
explicitly here so no engineer re-litigates it mid-implementation.

A new `showsParkMyCarTile: Bool` init param (default `false`, additive-safe — same convention
`allowsReposition`/`onRequestStreetClosure` already used) gates tile 0. `true` at both resting
entry points (long-press, pill); `false` at the in-drive Report button's call site, with a
comment citing the reason (Drive Mode parking is TF2-7's dedicated arrival-prompt flow, not this
chooser — see §5).

### 3.2 Entry point rewiring

**`handleLongPress(at:)`** (`ContentView.swift:4266-4305`): drop the
`longPressPresentationMode`/`LongPressPresentation` branch entirely. Every resting long-press
(driving/block-select guards unchanged) does the same three things, for both flag states:
1. Drop a tentative marker at the exact coordinate (§3.4).
2. Pre-resolve candidates the same way the legacy dialog's "Report enforcement or sweeper"
   button already does (`findCandidateSegments` + `CandidateSegmentSearch.confirmStreetCandidates`,
   `ContentView.swift:1143-1154` — reused verbatim, not reinvented).
3. Present `activeSheet = .reportPin(coord:, streetName: nil, segment:, confirmCandidates:,
   coordinateSource: "long-press (resting)", showsParkMyCarTile: true)`.

`communityEnabled == false` collapses to the 1-tile chooser (OD-5) — visually identical to
today's `LongPressParkConfirmCard`, reached through this same path.

**`handleReportPillTap`** (`ContentView.swift:2356-2369`): already does steps 2–3 today (it's
literally what `ReportSheet` already is). The only change is passing `showsParkMyCarTile: true`
and dropping a tentative marker before presenting, matching the long-press path's shape exactly —
this is near-zero-diff for the pill.

**In-drive Report button** (`driveActionRow`): unchanged destination shape, `showsParkMyCarTile:
false` explicit at the call site (mirrors the retired `allowsReposition: false` convention).

### 3.3 Why this doesn't repeat the tap-through-a-presented-sheet bug

There is no map-tap handling anywhere in this flow while a sheet is presented. The coordinate is
fixed in step 1, before `activeSheet` is ever set. `ActiveSheet.reportPin`'s `Identifiable` id
stays keyed off the coordinate (`ContentView.swift:369`, unchanged) — and that's now **correct**,
not a landmine, because nothing inside the sheet's lifetime ever tries to mutate that coordinate.
If the user wants a different point, they dismiss (Cancel, swipe-down, or submit-elsewhere) and
long-press/pill-tap again — a brand-new coordinate legitimately deserves a brand-new sheet
identity and fresh `@State`. #118's entire §3.2/§3.3 (the landmine + the `ReportRepositionUpdate`
side-channel built to avoid it) becomes unnecessary machinery, deleted wholesale (§6).

### 3.4 Tentative marker

Use `DraftSpotPinAnnotation` (`Views/MapViewRepresentable.swift:189-193` — `mappin.and.ellipse`,
`.systemBlue`, alpha 0.85, "not yet posted") as the **type-neutral** marker shown while the
chooser is open, for both long-press and pill entries. It's already exactly the right semantic
("a point not yet committed to anything"), and reusing it needs no new annotation class. On
submit, it's replaced by the type-specific marker that type already uses today (solid blue car
for Park, teal/cyan for enforcement/sweeper, etc.) — no change to any existing post-submit
rendering. On dismiss/cancel, it's removed, full stop (§3.3).

### 3.5 Flag/gating matrix

| Entry | `communityEnabled` | Tiles shown |
|---|---|---|
| Long-press (resting) | `false` | Park my car (1 tile, collapsed chooser — OD-5) |
| Long-press (resting) | `true` | Park my car, Enforcement, Sweeper, Spot open, Street closure |
| Report pill | `false` | Pill itself is already flag-gated (`communityMapChromeVisible`) — N/A, pill doesn't exist flag-off |
| Report pill | `true` | Same 5 tiles as long-press |
| In-drive Report button | `true` only (button is flag-gated) | Enforcement, Sweeper, Spot open, Street closure — **no Park tile, ever** |

---

## 4. Work streams

Single `@ios-engineer`, serialized — `ContentView.swift` and `Views/ReportSheet.swift` are both
wanted by every stream here, and this repo's own standing note is explicit that file contention,
not agent count, is the bottleneck. Sequence, per OD-6 (stage the risky core change first):

1. **Stream 1 — Park tile + grid plumbing (own small PR).** Add `.parkMyCar`/`.parkMyCarHandoff`
   to `ReportSheet`'s enums, wire the handler to reuse `confirmLongPressPark(at:)`'s existing
   logic verbatim, add `showsParkMyCarTile`. No entry-point rewiring yet — nothing user-visible
   changes in this PR. Pure additive scaffolding, fully unit-testable without touching
   `ContentView.swift`'s presentation logic. **~0.5 session.**
2. **Stream 2 — rewire the two resting entry points + retire the legacy dialog/slim card
   (own PR, the risky one).** `handleLongPress`, `handleReportPillTap`,
   `longPressParkConfirmOverlay`, `LongPressPresentation`/`longPressPresentationMode`,
   `communityMapChromeVisible`'s `longPressParkConfirmActive` param, the legacy
   `.confirmationDialog`, `showRestingActionMenu`, `LongPressParkConfirmCard.swift` (delete the
   file). This is the one touching the highest-traffic path in the app — budget real care and a
   dedicated Mac-gate live smoke (§7). **~1–1.5 sessions.**
3. **Stream 3 — delete #118's dead reposition machinery.** `ReportRepositionUpdate`,
   `repositionUpdate`, `reportRepositionModeActive`, `showsRepositionAffordance`, the
   `handleMapTap` reposition branch, the never-merged #118 branch itself. Can ride inside Stream
   2's PR (same files already open) or its own tiny cleanup PR — engineer's call. **~0.5 session.**
4. **Stream 4 — OD-4's Spot-open one-tap-done for long-press entry, if Kevin confirms.**
   Isolated to `ReportSheet`'s `.spotPlacementHandoff` path + whatever `SpotPlacementView` call
   needs to accept a pre-placed coordinate instead of requiring its own tap. **~0.5 session.**

**@designer** — one review pass on the chooser's tile layout (full-width Park row vs. 5-cell
grid), runs **in parallel** with Streams 1–2; non-blocking, engineer ships a reasonable default
and swaps styling after feedback without re-architecting anything.

No `@backend-data` work (zero schema touch, zero migration). No `@pwa-maintainer` work (iOS-only
scope — the PWA stays in maintenance mode, untouched).

---

## 5. Acceptance criteria

- [ ] **AC-1:** Resting long-press (not driving, not mid-block-select) always plants a tentative
  marker at the exact pressed coordinate and opens the chooser — no confirmationDialog, no
  `LongPressParkConfirmCard`, for either flag state.
- [ ] **AC-2:** Report pill tap always plants a tentative marker at the resolved
  GPS/map-center coordinate and opens the same chooser mechanism as AC-1 (same `ActiveSheet`
  case, same presentation path).
- [ ] **AC-3:** `communityEnabled == false`: the chooser collapses to exactly one tile ("Park my
  car here"), visually and behaviorally matching today's `LongPressParkConfirmCard` copy.
- [ ] **AC-4:** `communityEnabled == true`, resting entry (long-press or pill): chooser shows
  Park + the 4 existing community tiles, unchanged copy/icons/border colors from today's grid.
- [ ] **AC-5:** In-drive Report button entry never shows the Park tile — community tiles only,
  byte-identical to today's in-drive `ReportSheet` behavior.
- [ ] **AC-6:** Selecting "Park my car here" performs the identical write path as today's
  `confirmLongPressPark`/legacy-dialog-button — same candidate search, same `PinDropIntent`
  construction, same downstream confirm step — proven via a byte-identical-wire-shape test
  (mirrors #118 QA's own FT-11 fast-path proof technique).
- [ ] **AC-7:** Selecting Enforcement/Sweeper enters the same confirm-street/sub-tag/heading flow
  as today, anchored to the entry coordinate — **no in-sheet "Reposition" control exists** (it's
  deleted, not hidden).
- [ ] **AC-8:** Selecting Spot open / Street closure hands off exactly as today — unchanged
  `spotPlacementHandoff`/`streetClosureHandoff` destination behavior (modulo OD-4's confirmed
  one-tap change for long-press-sourced Spot-open, if approved).
- [ ] **AC-9:** Dismissing the chooser (Cancel / swipe-away) removes the tentative marker with
  zero residual state — a fresh long-press/pill-tap elsewhere produces an entirely independent
  chooser. This is the explicit correction path and must be demonstrated live, not just asserted.
- [ ] **AC-10:** No map-tap handling exists anywhere in the codebase that fires while this
  chooser is presented — grep-verifiable: the `handleMapTap` reposition branch and
  `reportRepositionModeActive` no longer exist.
- [ ] **AC-11:** Fast-path tap count for "report/park where I'm standing" via the pill is no
  worse than pre-change (pill tap → tile tap → existing per-type steps) — no new mandatory screen
  inserted; QA report walks both flows side by side and states the count explicitly.
- [ ] **AC-12:** `LongPressParkConfirmCard.swift`, `ReportRepositionUpdate`, `repositionUpdate`,
  `reportRepositionModeActive`, `showsRepositionAffordance`, `LongPressPresentation`/
  `longPressPresentationMode`, and the legacy three-button `confirmationDialog` are all deleted —
  zero dead code remains from either the pre-S13c dialog era or the retired #118 branch.
- [ ] **AC-13:** #121's curb-snap-on-display projection is unaffected — pins from both entry
  paths still render on-curb (confirmed independently, not re-derived here).
- [ ] **AC-14:** All chooser tiles, including the new Park tile, meet the established >=44pt
  generous-touch-target convention (`driveActionRow`'s 48pt precedent).
- [ ] **AC-15:** No "avoid," "ticket," "fine," "evasion," or "dodge" language in any new or
  changed copy, including the chooser's title and the Park tile's sublabel.
- [ ] **AC-16 (Mac-gate, live device):** Long-pressing a precise curb point and selecting
  Enforcement submits the report at the **exact long-pressed coordinate**, not GPS, not
  map-center — the entire point of this feature, provable only on real hardware where GPS and
  the long-press point genuinely differ.

---

## 6. Migration, risk, and phasing

- **This is the single most-used, unflagged core interaction in the app** (parking via
  long-press). Treat Stream 2 (§4) with the same rigor the #22 spec demanded for its own
  tap-to-reposition work — elevated QA, a dedicated Mac-gate live smoke, not a drive-by review.
- **Not feature-flagged.** `communityEnabled` already governs which tiles show (§3.5) — there is
  no need for a *second*, holdout-style flag around the chooser mechanism itself, because OD-6's
  staged-PR sequencing (Park-only plumbing first, community tiles second) already isolates risk
  without the overhead of a flag that would need its own later removal.
- **Regression surface:** every resting long-press and every Report-pill tap, for every user,
  both flag states. The QA pass for Stream 2 must explicitly re-verify Park drops a pin
  correctly for a FLAG-OFF smoke (the highest-exposure surface, since flag-off has had zero
  community UI changes in a long time and must not regress now).
- **#118 disposal:** recommend Kevin skip its pending Mac gate entirely rather than spend a
  session compiling/merging code this spec deletes in Stream 3. Close the open item with a note
  pointing here, same as this file's own header does.
- **#121 is unaffected and should proceed independently** — it fixes where a pin *renders*, this
  spec changes how a pin gets *created*. No shared code path, no ordering dependency.
- **The SwiftUI-presentation lesson, stated plainly for the next engineer who reads this:** the
  recurring failure class across #118 and the legacy dialog's #17b bug was always the same shape
  — mutating state that a live `.sheet(item:)`/`.confirmationDialog(isPresented:)` depends on,
  *while* that presentation is in flight or already up. This spec's entire structural argument is
  that fixing the *order of operations* (place first, never touch the map again once a sheet
  exists) eliminates the precondition for that whole bug family, rather than adding another guard
  on top of it. Any future chooser-adjacent change should preserve that ordering invariant rather
  than re-introduce an in-sheet map interaction.

---

## 7. QA notes (for `@qa-verifier`, when this is implemented)

- Elevated rigor, 1.5–2 passes minimum, given the unflagged blast radius — same posture
  `docs/report-tap-to-place-spec.md` §4 demanded of its own PR.
- Explicitly re-verify flag-off parking (the single highest-traffic, highest-regression-cost
  path in the app) is byte-identical pre/post, not just "looks the same."
- Verify AC-9 (dismiss-and-redo) live, not just by code trace — this is the feature's entire
  answer to "what if I pointed at the wrong spot," and it must feel immediate, not punitive.
- Verify AC-16 on real hardware with a real GPS/long-press delta (e.g., long-press a point ~15m
  from where you're actually standing) — simulator GPS can't prove this distinction.
- Confirm no dead references to any of the AC-12 deletions remain (compiler will catch most of
  this, but doc comments/tests referencing retired concepts should be cleaned too).

---
---

## Amendment — fixed-center pin with live curb snap (Kevin, 2026-10-23)

**Status:** spec-first, not started. Amends this document; S1 (#122, Park-tile plumbing, dormant)
stands and is reused. Where this amendment and §§3.2/3.4/5/6 above disagree, **the amendment wins
for the flag-on path** (supersession table in A.8). Original text is not edited, per house rule.
**Author:** @tech-lead. **Trigger:** Kevin reviewed Makeway (Hoboken paid spot-sharing) and loved
"Pin your spot": a FIXED needle pin at screen centre, the map pans/zooms under it at
building-number zoom, a card names the resolved place, ONE primary "Next". His words: "much more
straightforward than our location selection process." Their flaw, which we must not copy: the
card said "245 Bowery" while the pin sat on Stanton St — a nearest-building label. For
alternate-side rules the unit of truth is **street + side (blockface)**, not an address.

### A.0 Open decisions for Kevin (everything else below is decided; veto any time before the gate)

| # | Decision | Recommendation |
|---|---|---|
| A-1 | **Primary button on long-press entry when `communityEnabled`.** Approved model says long-press ends in the 5-tile chooser; Kevin's new ask is one primary button. Literal reading = long-press -> adjust -> "Next" -> chooser -> Park tile: **Park costs 2 taps after the press (today: 1).** | **Primary = "Park here"** (commits in one tap, the dominant action), plus ONE quiet full-width text link under it, "Report something here", that opens the chooser (Park tile hidden) — only when `communityEnabled`. The card still has exactly one *primary* button and no alternatives list. Pill entry (report intent) keeps "Next" -> chooser. If Kevin wants the literal "Next"-everywhere, it is a one-line label/route change in `CurbPlacementCardModel` (A.4) — cheap to flip, so the ruling can wait for the Mac gate. |
| A-2 | **Report pill now lands in placement first (+1 tap vs today's pill -> grid).** Supersedes base AC-11 for flag-on. | **Accept.** The pin starts on the GPS curb (usually already correct), so the added tap is a "yes, this side" confirm — the exact failure (wrong side / wrong street) the new mode exists to kill. Mitigation: pill-entry zoom/centre is instant (no animation) so the screen is ready on arrival. |

**RULED 2026-10-23 (orchestrator, under Kevin's standing autonomy directive — veto-able any time
before the flag flips):** **A-1 = adopt the recommendation** (primary "Park here" + one quiet
"Report something here" link when `communityEnabled`; pill entry keeps "Next" -> chooser).
**A-2 = accept** (pill lands in placement first, +1 confirm tap). Both are cheap to flip later
(label/route in `CurbPlacementCardModel`), so Kevin's Mac-gate reaction is the real test.

**STREAM B DESIGN REVIEW LANDED 2026-10-23 — `docs/design/curb-pin-placement-design.md` is AUTHORITATIVE
over this amendment wherever the two differ** (adopted by the orchestrator under the autonomy directive).
Two blockers it found in the amendment, both resolved in its favour: (1) **pin tip at 40% of screen
height (not bounds centre) + zoom floor ~0.55x entry distance + card height cap** — otherwise the card
can cover the pin/ghost/highlight, tight on SE-class phones; (2) **VoiceOver cannot pan the map**, so the
mode ships an adjustable summary element that cycles nearby curbs with ordered labels and debounced
announcements. Also adopted: the 4-layer highlight stroke (the amendment's white-14/core-9 is invisible on
a light basemap), the opaque `secondarySystemBackground` card with `Color(.label)` text (never
`.secondary`), the 60 pt white-capsule primary (system-blue prominent fails 4.5:1), status chip with an SF
Symbol, 48 pt "Report something here" row, labelled Cancel capsule, first-use hint pill. Its contrast
numbers are estimates pending Mac/outdoor verification.

Everything else (new flag, snap numbers, arrival prompt untouched, Path B routed through the new
mode, cancel restores the camera) is a tech-lead decision with reasoning below.

### A.1 Problem & user story

Today there are three different ways to say "here": long-press (blind point -> `findCandidateSegments`
-> `ParkConfirmView`'s "Wrong street?" list of up to 3 alternatives within 35 m,
`ContentView.swift:5184-5204`, `Views/ParkConfirmView.swift:14`), the report pill (GPS seed ->
confirm-street list of up to 4, `ContentView.swift:2873`), and Spot-open's tap-the-curb
(`handleSpotPlacementTap`, `ContentView.swift:4715-4730` -> `CandidateSegmentSearch.nearestSegmentSnap`,
`CandidateSegmentSearch.swift:169`). Each ends in "pick from a list" — Kevin calls that
"location selection process" and it is the part that feels backwards: the user must read street
names to fix a map problem.

**New story:** I long-press (or tap Park here / the Report pill). The map jumps to street level
with a needle pin dead centre. I drag the map; a bold highlight tells me which curb of which block
the pin belongs to, and a card reads "Stanton St · South side — Free until Tuesday 8:00 AM". If the
highlight is the wrong curb I nudge the map until it is the right one — no list, no wrong-street
sheet. One big button commits.

### A.2 Scope

**In:** one placement mode (`CurbPlacementSession`) used by (1) resting long-press, (2) report pill,
(3) BlockDetail "Park here ->" (Path B, `ContentView.swift:5207-5232`, midpoint seed, that block
pre-selected as incumbent) — all behind one new flag; pure snap engine + spatial index;
needle/ghost/tether reticle; blockface highlight; card; camera enter/exit; handoffs to the existing
park-commit path, `ReportSheet`, and Spot-open; chrome gating; ACs and live smoke.

**Out (decided):**
- **Drive Mode arrival prompt (W8.5d, `ContentView.swift:1718-1775`) and in-drive "Park here"
  (TF2-7 sign-check -> `ParkConfirmView`) are UNCHANGED, byte-for-byte.** The driver cannot pan a
  map; these are the safety-first flows base §2 already carved out. "Must keep working" = zero diff
  there; AC-A28 proves it. (Follow-up A.13-1 offers a headless snap for the arrival car.)
- Street closure (multi-block select) — still a handoff tile, not a point placement.
- Retiring legacy long-press paths (dialog, `LongPressParkConfirmCard`, `#118` remnants). Flag-off
  keeps them untouched; deleting them becomes cleanup AFTER the flag flips (re-scopes S2, A.9).
- PWA, backend, schema, tiles. iOS only.

### A.3 Interaction model

All behaviors are testable. Numbers are starting values the designer/Mac gate may tune, but each
MUST exist as a named constant in `CurbSnapConfig`.

**Entry.** Guard: `!driveModeActive && !blockSelectModeActive && !spotPlacementActive &&
curbPlacement == nil`. Sets `activeSheet = nil` (same as `enterSpotPlacementMode()`,
`ContentView.swift:4870`), snapshots the current camera (center, distance, **pitch**, heading,
map style), then animates to the entry camera: centered on the seed point, **pitch 0, heading 0
(north-up)**, visible width **~110 m (~0.28 m/pt on a 390 pt screen)** — chosen so a typical 15 m
street's two curbs sit ~55 pt apart, which is what makes "pan until the right curb lights up"
a finger-sized task (at the base-map default zoom they would be ~20 pt apart and unusable). Seeds:
long-press = pressed point; pill = GPS else `region.center` (existing chain, `ContentView.swift:2873-2876`);
Path B = block midpoint. Pitch flatten matters for flag-on ambient screens: the Option-A opening
look is tilted (`docs/drive-mode-default-spec.md` ruling 6) and a tilted camera makes "ground point
under the pin" and curb separation ambiguous.

**While active.** `setCameraZoomRange` is tightened to max center distance **~400 m** (restored on
exit) so the snap radii below never fall under ~40 pt; no minimum (same as the existing range,
`MapViewRepresentable.swift:1156`). Pan/pinch are the only gestures that matter; tap and
long-press on the map are no-ops in this mode (the base §3.3 ordering invariant, strengthened:
**map interaction exists only here, never while any sheet is up**).

**Reticle (one UIKit view, not an MKAnnotation).** A non-interactive `PlacementReticleView` is
added to the map on entry and removed on exit via the `CoordinatorActions` bridge (the #31 rule:
no mount-time UIKit mutation in `updateUIView`). It owns three things drawn in one coordinate
space so they cannot misalign: the **needle pin** (tip exactly at the map view's bounds centre),
the **snap ghost** (a 12 pt white dot with black ring ON the snapped curb point), and a **tether**
(2.5 pt line pin tip -> ghost, hidden when distance < 4 pt). The pin lifts 8 pt with a larger
shadow while a pan/pinch recognizer is active and drops on settle (skipped under Reduce Motion).
This is how "the pin snaps live" is rendered honestly: the map is moving under a fixed pin, so
the pin cannot literally slide onto the curb; the ghost+tether show where it WILL land, and the
settle step below makes it land.

**Settle nudge.** When the gesture ends and the map has stopped (`regionDidChangeAnimated`, no
active recognizer, no deceleration), and there is a snapped result with distance > 0.5 m, animate
`setCenter(snappedCoordinate)` (~180 ms ease-out) so the curb point ends up under the pin tip and
the tether collapses. A coordinator-owned `isProgrammaticNudge` flag suppresses a second nudge from
the resulting region callback (no feedback loop). Along-curb position stays exactly where the user
left it (the snap is the perpendicular foot point, not the block midpoint). The coordinate saved is
this snapped point — same convention as Spot-open (`SpotPlacementDraft.coordinate`,
`SpotPlacementView.swift:44-53`) and #121's on-curb display.

**Snap rule (live, `CurbSnapEngine.resolve`).** Input: pin ground coordinate
(`mapView.centerCoordinate`), the previous winner's `blockfaceKey` (incumbent), `CurbSnapConfig`.
1. Candidate set = loaded segments whose polyline passes within **acquire radius 24 m** (physical
   metres; covers the centre of a ~48 m avenue where each side is ~12-15 m away — Houston/Bowery use
   ~12.7 m side offsets per HANDOFF's width-offset notes; covers nothing inside a building lot, by
   design).
2. De-duplicate by `blockfaceKey` (`Models/Segment.swift:173`, street|from|to|side) keeping the
   minimum distance — the same blockface can appear in two tiles at an edge.
3. **Hysteresis (anti-flicker):** a challenger replaces the incumbent only if
   `challengerDistance < incumbentDistance - H`, where `H = clamp(8 pt x metersPerPoint, 1.5 m, 4.0 m)`
   (screen-space dead-band: ~2 m at entry zoom, zoom-invariant to the finger). The incumbent is
   kept while within **release radius 30 m** (1.25x acquire). With no incumbent the winner is the
   nearest. Net effect: standing on the centreline between two curbs, the highlight does not
   oscillate; you commit to a side by moving ~2 m past the middle toward the other curb.
4. **Deterministic ties:** sort by (distance, blockfaceKey); never depend on array order or dictionary
   iteration (base `findCandidateSegments` iterates a dictionary — fine for a one-shot tap, a
   flicker source at 30 Hz).
5. Only the winner's `positionFraction` + foot point are computed (via the existing
   `nearestPointOnPolyline`, `CandidateSegmentSearch.swift:209`); the candidate scan uses a
   distance-only kernel with no allocation.
6. Output: `.snapped(CurbSnapResult)` or `.noCurbInRange(nearestMeters: Double?)`.

**Corners and gaps.** At an intersection two blockfaces are a few metres apart; hysteresis + the
dead-band make the first one you settle on stick. Curb lines end short of the crosswalk, so a pin
dead-centre in an intersection may snap 10-15 m up a side street — the tether makes that visible and
it is correct (you are choosing a block). **Divided/multi-carriageway streets** (FT-21 per-carriageway
geometry, shipped build 24) produce extra parallel lines; the same rule applies, no special case.

**One-way and side assignment.** Side is the tile's compass label (N/S/E/W) rendered by
`ReportSheet.sideDisplayName` (`Views/ReportSheet.swift:1662`) — direction of travel never enters
the label, so one-way streets need no left/right logic. Known edge: a block where only ONE side has
rule data loaded (sparse coverage, `CandidateSegmentSearch.oppositeSideCandidate` returns nil) —
a pin on the data-less curb snaps to the far curb up to 24 m away. We do not guess the centreline;
the tether + highlight show the user exactly which curb is being claimed, and the card appends
"(nearest curb with data)" in `.secondary` text when snap distance > 15 m AND no opposite-side
segment is loaded. Acceptable limitation, QA'd (AC-A12).

**No curb in range.** Highlight/ghost/tether hidden. Card: title "No curb here", subtitle "Move the map
until the pin is near a street", plus a small arrow chip pointing toward the nearest curb within
100 m if one exists (cheap: reuse the index with a larger probe; omit if none). **Park intent: the
primary button stays enabled as "Save car here (no parking info)"** — this is today's
`detectedSegment == nil` path and is the only way Brooklyn/outside-coverage users can mark a car
(Brooklyn tiles are not shipped, `docs/brooklyn-expansion-spec.md`). Report intent: "Next" stays
enabled with `segment: nil` (existing OD-1 graceful degradation, `ActiveSheet.reportPin` doc,
`ContentView.swift:259-260`). **Never dead-end the user.** Tiles still loading: if
`tileLoader.segments` is empty or `segments.count` changed in the last 400 ms of a pan into new
territory, show "Loading curbs…" (not "No curb here") and re-resolve on the
`.onChange(of: tileLoader.segments.count)` hook (`ContentView.swift:2950`).

**Exit.** Cancel (48 pt X, top-left) -> restore the snapshot camera (animated), `activeSheet =
driveModeDefaultRestStateSheet()` (NOT a literal `.browseNav` — DM-1's QA found exactly that bug
class twice, `docs/drive-mode-default-spec.md:253-259`). Commit -> keep center/zoom (the car/pin is
what the user wants to see), but always restore **pitch, heading and map style** to the snapshot so
the Option-A driving look returns. Both paths remove the reticle and highlight overlays and restore
the zoom range.

### A.4 Card

A bottom-docked overlay in `ContentView` (the `SpotPlacementConfirmCard` pattern,
`ContentView.swift:2557-2590` — NOT a sheet and NOT an `ActiveSheet` case: a sheet over a live,
panning map is the exact #118 failure class base §1 describes). Pure model drives it:

```swift
// Views/CurbPlacementCard.swift — pure, nonisolated, unit-tested
enum CurbPlacementIntent: Equatable { case park, plant, report, parkBlock }
struct CurbPlacementCardModel: Equatable {
    let title: String            // "Stanton St · South side"  (canonical street + sideDisplayName)
    let subtitle: String         // "between Bowery & Chrystie" (canonical cross streets)
    let safetyText: String?      // engine.safetyLabel(for:).text — verbatim, e.g. "Free until Tuesday 8:00 AM"
    let severity: SafetyLabel.Severity?
    let primaryTitle: String     // "Park here" | "Next" | "Save car here (no parking info)"
    let primaryEnabled: Bool     // false only while "Loading curbs…"
    let secondaryTitle: String?  // "Report something here" iff intent == .plant && communityEnabled
    nonisolated static func make(outcome: CurbSnapOutcome, intent: CurbPlacementIntent,
                                 communityEnabled: Bool, engine: ParkingRulesEngine,
                                 now: Date) -> CurbPlacementCardModel
}
```

- Title/subtitle use the same helpers `ReportSheet`'s confirm rows use (`StreetNameNormalizer.canonical`,
  `ReportSheet.sideDisplayName`, `Views/ReportSheet.swift:1065-1068`). The cross-street line is the
  anti-Makeway guard: orientation without an address.
- Status line is `ParkingRulesEngine.safetyLabel(for:at:)` (`Services/ParkingRulesEngine.swift:74`),
  rendered in the TF2-18 solid-fill chip anatomy (`Views/DriveModeBottomCard.swift` chip builders). Do
  NOT write a second status formatter; QA compares card text to `BlockDetailView` for the same segment.
- **Exactly one primary button**; at most one text-weight secondary (A-1). No alternatives list, no
  Cancel button inside the card (Cancel is the top-left X).
- Reminder opt-in: defaults ON and is changed in `ParkedCarDetailView` — the same precedent the arrival
  path already ships (`notifyOnRestriction: true  // default on, user can toggle in ParkedCarDetailView`,
  `ContentView.swift:1743-1757`). The dropped `ParkConfirmView` toggle is not lost.
- Card update cadence: SwiftUI state is written only when `(blockfaceKey, outcome kind)` changes or on
  the settle callback — **never per frame**. FT-17a already measured the cost of per-callback SwiftUI
  writes during a gesture (felt jank; see the `hasSignaledFollowPauseThisGesture` comment in
  `MapViewRepresentable.swift`). Ghost/tether geometry updates imperatively inside the coordinator.

### A.5 Sunlight legibility and touch targets (explicit, because both have history)

History: TF2-18 found the old chips failed WCAG on the light scheme (1.4-2.6:1), fixed to 5.9-10.4:1;
Kevin confirmed sunlight readability on the LIGHT scheme only (build 16, 2026-08-19,
`docs/field-testing-log.md:653-690`); FT-20 then forced Dark and `Services/ParkingColors.swift`'s audit
states outright that dark-scheme direct-sunlight legibility is **unvalidated**. So this mode is
designed for the worst case on both basemaps:
- Card: **opaque** solid fill (not `.regularMaterial`, which every current sheet uses), primary text
  >= 7:1 (AAA) against it; status chip = shipped solid-fill + black-text anatomy; button text >= 4.5:1
  on its fill; all contrast ratios computed and pasted in the PR (as TF2-18's QA did).
- Needle: white fill, 2 pt black outline, 44 pt head, hard shadow — reads on a tan day map and a black
  night map. **Do not reuse** `DraftSpotPinAnnotation` (alpha 0.85, "not yet posted" look,
  `MapViewRepresentable.swift:189`) or `PendingParkPinAnnotation`'s dimmed tentative state
  (`:201`) — dimness is the antipattern.
- Highlight: white **casing** 14 pt under a 9 pt core in the blockface's current severity colour (the
  map already paints every curb in a severity colour, so a same-colour highlight would not stand out;
  the casing is what carries it). Other curbs stay at normal opacity (do not dim data to make the
  highlight pop). Browse width is 4.5 pt, drive 8 pt (`CurbLineWidth`), so 9/14 is unmistakable.
- **Touch targets (Kevin's standing preference, PR #110 gate):** primary button >= 56 pt tall,
  full width minus 16 pt margins; Cancel X and a "locate me" button 48x48 pt; secondary text link
  48 pt tall full width. Nothing in the card or chrome smaller than 44 pt in either axis.
- Kevin-gated daylight check: the flip waits on his outdoor look at this mode on the dark scheme
  (add to his next drive-test checklist). It cannot be automated; do not claim it.

### A.6 Architecture

**Codebases:** iOS only. No backend, no PWA, no tile change.

**Flag.** `AppConstants.curbPinPlacementEnabled = false` (same convention as `driveModeDefaultEnabled`,
`Services/Constants.swift:262`). Independent of `communityEnabled` and `driveModeDefaultEnabled`.
Flag off: `handleLongPress`, `handleReportPillTap`, `initiatePathBPinDrop` and every chrome function
take their existing branches with the new parameters defaulted — byte-identical. This replaces base
§6's "not feature-flagged" for the NEW behavior only: that argument avoided a second flag around an
unflagged rewiring; here the risk is a new live-gesture camera mode plus unvalidated outdoor
legibility, and a flag is what decouples it from S2's unflagged blast radius (A.9).

**State.** One `@State private var curbPlacement: CurbPlacementSession?` (struct: intent, seed,
camera snapshot, latest `CurbSnapOutcome`). `curbPlacementActive` derived Bool is threaded as a new
trailing default-`false` parameter into every pure chrome-visibility function that already takes
`spotPlacementActive`/`blockSelectModeActive` (grep both; `ContentView.swift` ~2700-2770, ~3193-3201,
~6060-6095), so Report pill, "?" key, goal dock, search chrome and browse sheet all hide — the DM-2
goal-first screen included. The generic `.sheet(onDismiss:)` catch-all (`ContentView.swift:1203-1206`)
gets `&& curbPlacement == nil` (it already carries `!spotPlacementActive`). **No read or write of
`driveModeActive`, `driveModeStyle`, or `LocationService` drive posture anywhere in this mode** — the
two-posture invariant in `docs/drive-mode-default-spec.md` §3.1 holds: placement is a *resting-posture*
mode (entry guard requires `!driveModeActive`); the locate button uses the existing single-shot
`requestAndFetchLocation()`. Camera work goes through `CoordinatorActions` called from
`.onChange(of: curbPlacement != nil)`, OUTSIDE `updateUIView` (#31).

**Spatial lookup / performance.** `Services/CurbSnapIndex.swift` (new, pure, `nonisolated`):
project all polyline *edges* to local metres (fixed NYC origin, equirectangular — the repo's existing
geometry helpers already use this approximation, `CandidateSegmentSearch.swift:323-330`), bucket edges
into a **32 m uniform grid** (an edge registers in every cell its bbox crosses). Query = the pin's cell
+ 8 neighbours (covers the 30 m release radius), distance-only kernel (no haversine, no per-call
arrays). Contrast `nearestSegmentSnap`: it rebuilds a cumulative-length array with haversine per
candidate segment per call — fine for one tap, far too heavy for 30 Hz over thousands of segments.
Index is built lazily on entry and rebuilt on `tileLoader.segments.count` change, on a detached task
with a generation token (stale results discarded); build target < 60 ms for ~5k segments, query target
< 1 ms on iPhone 12-class, both asserted with `measure {}` tests on a synthetic 5k-segment fixture
(budget numbers are targets to be confirmed at the Mac gate, not guarantees). Driver loop: a
`CADisplayLink` at `preferredFramesPerSecond = 30`, created on entry, paused when idle, invalidated on
exit (no retain cycle: weak coordinator); each tick reads `mapView.centerCoordinate`, skips if it moved
< 0.15 m since the last resolve. MapKit has no `regionIsChanging` delegate callback, so this is the
standard approach; `regionDidChangeAnimated` triggers one final resolve + the settle nudge.

**Handoffs (all reuse existing paths; nothing new on the wire).**

| Intent / button | Result |
|---|---|
| `.park`/`.plant`/`.parkBlock` + "Park here" | Build `PinDropIntent(pinLat/pinLng = snapped coord, detectedSegment: winner, detectedSegmentDistance: d, alternativeCandidates: [])` -> `PinConfirmResult(notifyOnRestriction: true)` -> existing `confirmPinDrop(result:)` (`ContentView.swift:1443-1450`). `ParkConfirmView` is skipped for flag-on; its commit path is not forked. |
| `.report` "Next" / `.plant` secondary | Exit mode, then `activeSheet = .reportPin(coord: snapped, streetName: nil, segment: winner, confirmCandidates: confirmStreetCandidates(winner), coordinateSource: "curb-snap placement (<entry>)")` with `showsParkMyCarTile` per S1 (true for pill, false for the long-press secondary link since Park is the card's primary). Coordinate is fixed BEFORE the sheet exists (base §3.3 invariant intact; `ActiveSheet.reportPin` id stays coordinate-keyed and is now correct). |
| Spot open tile | Pass `(winner, positionFraction, snapped)` straight into `SpotPlacementDraft` and go to its confirm card, skipping the separate tap step — this is the base OD-4 / 2026-10-02 "Spot-open one-tap" ruling falling out for free. |
| Street closure tile | Unchanged `streetClosureHandoff`. |

### A.7 Entry-point matrix

| Entry | Flag off | Flag on |
|---|---|---|
| Resting long-press | Today's dialog (`!communityEnabled`) / slim card — untouched | Placement, seed = press point, intent `.plant` |
| Report pill | Today's grid sheet | Placement, seed = GPS/centre, intent `.report` -> "Next" -> chooser |
| BlockDetail "Park here ->" | Today's `ParkConfirmView` | Placement, seed = block midpoint, that blockface is the incumbent, intent `.parkBlock` |
| In-drive Report button | unchanged | unchanged (driving; no placement) |
| In-drive "Park here" (TF2-7) | unchanged | unchanged |
| **Arrival prompt (W8.5d)** | unchanged | **unchanged** (`driveModeActive` is true there; this mode's entry guard excludes it) |

### A.8 What this supersedes in the base spec (flag-on only)

| Base item | Now |
|---|---|
| §3.2 steps 1-3 (long-press drops marker and immediately opens chooser) | Long-press enters placement; chooser reached via the pill's "Next" or the card's secondary link |
| §3.4 `DraftSpotPinAnnotation` as tentative marker | The needle pin; `DraftSpotPinAnnotation` untouched and still used by Spot-open's own draft |
| OD-5 flag-off collapse | Unchanged and orthogonal (flag-off = legacy; flag-on + `!communityEnabled` -> card has no secondary link) |
| AC-1, AC-2 | Reworded: press/pill opens placement (A.11); chooser follows per A.7 |
| AC-9 dismiss-and-redo | Correction path is now "keep panning, or Cancel" — strictly better |
| AC-11 pill tap count | +1 tap accepted (A-2); QA states the count |
| §6 "Not feature-flagged" | New flag for the new behavior (A.6) |

Report-flow open item #22 (already superseded by this spec) is now satisfied by the same component;
nothing separate to build.

### A.9 Work streams (iOS only; blind-build — no Swift toolchain on the VPS)

Every `@ios-engineer` brief MUST paste all six compile-failure classes
(`memory/project_swift_compile_failure_classes.md`: literal-receiver inference, labeled-argument
order, memberwise-init order, XCTestCase-extension name shadowing, MainActor default isolation ->
explicit `nonisolated` on pure statics called from sync XCTests, and `WePark.Category` qualification
in test targets). Dispatch with `isolation: "worktree"`, one simctl-created sim per concurrent agent.
Pure-logic streams are blind-buildable with high confidence; map/gesture streams are not — the
live-UI smoke gate (Mac) is mandatory before merge (W8.5c-polish revert precedent, `HANDOFF.md:74`).

**Seam contract (freeze this first so A1/A2/A3 can run in parallel):**

```swift
// Services/CurbSnapIndex.swift (A1 owns)
struct CurbSnapConfig { let acquireRadius = 24.0, releaseRadius = 30.0
                        let hysteresisPoints = 8.0, hysteresisMinMeters = 1.5, hysteresisMaxMeters = 4.0 }
struct CurbSnapResult: Equatable { let segment: Segment; let positionFraction: Double
                                   let distanceMeters: Double; let snappedCoordinate: CLLocationCoordinate2D }
enum CurbSnapOutcome: Equatable { case snapped(CurbSnapResult); case noCurbInRange(nearestMeters: Double?) }
final class CurbSnapIndex: @unchecked Sendable {
    init(segments: [Segment])
    func resolve(_ p: CLLocationCoordinate2D, incumbent: String?, metersPerPoint: Double,
                 config: CurbSnapConfig) -> CurbSnapOutcome
}
// MapViewRepresentable (A2 owns) — additive, default nil/no-op when flag off
var placementIndex: CurbSnapIndex?                       // nil => mode off
var onPlacementOutcome: ((CurbSnapOutcome) -> Void)?    // fired on blockface/outcome-kind change + settle only
// CoordinatorActions: beginPlacement(seed:) / endPlacement(restore: Bool) — called from ContentView .onChange
```

(`Segment` and `CLLocationCoordinate2D` are not `Equatable` today; A1 supplies the conformance or a
key-based `==`. Sketch only — real signatures are the engineer's.)

| Stream | Owner | Depends on | Parallel? |
|---|---|---|---|
| **A1 — snap engine + index + tests** | @ios-engineer | seam contract only | **Yes** (new files only) |
| **A2 — map layer**: `PlacementReticleView`, display link, highlight overlays, camera enter/exit/nudge, zoom range, pitch flatten/restore | @ios-engineer (separate worktree) | seam contract; stubs `resolve` until A1 lands | **Yes** with A1 and B |
| **B — design review** (card, reticle, highlight casing, outdoor contrast math, Reduce Motion) | @designer | none | **Yes**, non-blocking; engineers ship a defensible default (no Bash: orchestrator lands the file) |
| **A3 — ContentView mode**: `curbPlacement` state, chrome gating, card + model, three entry rewires, Park/Report/Spot handoffs, flag, tests | @ios-engineer | A1 API, A2 closures | **Serial after A1+A2 merge-ready** (`ContentView.swift` contention) |
| **C — downstream trims**: Spot-open skips its tap step; `ReportSheet` hides "confirm the street" when `placementConfirmed: true` (additive init param, default false) | @ios-engineer | A3 | Serial, after A3; optional for first TestFlight |
| **D — QA** | @qa-verifier | A3 (+C) | After; 1.5-2 passes, elevated (core parking path) |

No `@backend-data`, no `@pwa-maintainer`.

**Re-scoped S2:** long-press/pill chooser rewiring (base §4 Stream 2) now builds on this mode and the
flag; legacy-path deletion (dialog, `LongPressParkConfirmCard`, `showRestingActionMenu`) moves to a
post-flip cleanup PR, so S2 no longer carries unflagged core-path risk. Base Stream 3 (#118 deletion)
is a no-op if #118 was never merged.

### A.10 File table and risk

| File | Change | Risk |
|---|---|---|
| `Services/CurbSnapIndex.swift` (new) | grid index + resolve + config | Low — pure, unit-testable |
| `Services/CandidateSegmentSearch.swift` | none (reuse `nearestPointOnPolyline`, `confirmStreetCandidates`) | None |
| `Views/PlacementReticleView.swift` (new) | needle, ghost, tether, lift | Medium — pixel alignment, only provable live |
| `Views/MapViewRepresentable.swift` | display link, highlight overlays (2 polylines), nudge, zoom range, pitch, `CoordinatorActions` additions | **High** — the file behind the #31 and W8.5c-polish regressions; every camera mutation outside `updateUIView`; flag off must not add observers, overlays or links |
| `Views/CurbPlacementCard.swift` (new) | card view + pure model | Low-Medium |
| `ContentView.swift` | state, 3 entry sites, chrome-param threading, onDismiss guard, exit via `driveModeDefaultRestStateSheet()`, handoffs | **High** — core parking path; large file; Mac-gated |
| `Views/ReportSheet.swift` | A3: none. C: additive `placementConfirmed` param | Low |
| `Views/SpotPlacementView.swift` | C: accept a pre-snapped draft | Low |
| `Services/Constants.swift` | one flag | Low |
| Tests (new files) | engine, index perf, card model, hysteresis sim, flag-off wire proof | — |

### A.11 Acceptance criteria

Engine
- [ ] **A1** Resolving a point within 24 m of a fixture blockface returns that blockface with correct
  `positionFraction`, `distanceMeters`, and an on-polyline `snappedCoordinate`.
- [ ] **A2** Two parallel curbs 15 m apart, pin swept across at 1 m steps with an incumbent: the
  winner changes exactly once per sweep and does not return within the dead-band (hysteresis test,
  both sweep directions, plus a +/-0.3 m jitter variant that must produce zero flips).
- [ ] **A3** Equal-distance tie is deterministic across 100 shuffled input orders.
- [ ] **A4** Blockface present in two overlapping tiles resolves once (de-dup by `blockfaceKey`).
- [ ] **A5** Point > 30 m from every curb -> `.noCurbInRange`; incumbent retained between 24 and 30 m
  but never acquired in that band.
- [ ] **A6** Perf (Mac gate): index build and per-query timings on a 5k-segment fixture recorded in the
  PR against the A.6 targets; any miss is stated, not hidden.

Interaction and card
- [ ] **A7** Long-press with flag on enters placement centred on the pressed point at pitch 0,
  north-up, ~110 m visible width; two curbs of a ~15 m street are >= 48 pt apart at entry zoom.
- [ ] **A8** While a pan is active the highlight/ghost track the nearest curb with no visible flicker;
  on gesture end the map settles so the ghost sits under the pin tip within 0.5 m; no second nudge fires.
- [ ] **A9** Card title reads canonical street + side; subtitle reads the cross streets; status text is
  byte-equal to `engine.safetyLabel(for:)` for the same segment/time and matches `BlockDetailView`.
- [ ] **A10** Exactly one primary button exists; no alternatives list exists anywhere in the mode;
  secondary text link appears only for `.plant` with `communityEnabled`.
- [ ] **A11** No-curb state: highlight hidden, Park intent offers "Save car here (no parking info)",
  Report intent "Next" works with `segment: nil`; neither dead-ends.
- [ ] **A12** One-curb-has-data block: card appends "(nearest curb with data)" when distance > 15 m and
  no opposite-side segment is loaded; tether visible.
- [ ] **A13** Tiles-loading state shows "Loading curbs…" (not "No curb here") and resolves without any
  user action once tiles arrive.
- [ ] **A14** Cancel restores the exact prior center, zoom, pitch, heading, style and zoom range.
  Commit restores pitch/heading/style but keeps center/zoom.

Handoffs
- [ ] **A15** "Park here" persists a car at the SNAPPED coordinate with `detectedSegmentID` and side set;
  My Car renders it on the curb; reminder default ON; `confirmPinDrop` is the only commit path.
- [ ] **A16** Pill "Next" opens `ReportSheet` with the snapped segment pre-selected and coordinate
  fixed; submitting writes the snapped coordinate (not GPS) — provable on device with a >= 15 m delta.
- [ ] **A17** Spot-open from placement reaches its confirm card with no extra map tap (C).
- [ ] **A18** Path B enters placement at the block midpoint with that blockface highlighted.

Flag, state, invariants
- [ ] **A19** Flag off: `handleLongPress`/`handleReportPillTap`/`initiatePathBPinDrop` produce the same
  `activeSheet`/state transitions as main before this change (wire-shape tests, mirroring PR #118's
  FT-11 proof technique); no display link, overlay or reticle ever created.
- [ ] **A20** `driveModeActive` is never written by this mode; entry is rejected when it is true;
  `LocationService` drive posture (continuous GPS, wake lock) is never engaged — grep- and
  test-verifiable. With `driveModeDefaultEnabled` on, the ambient screen's tilted look returns after
  exit.
- [ ] **A21** Entering placement hides the report pill, "?" key, goal dock and browse sheet; exit
  restores via `driveModeDefaultRestStateSheet()` (flag-on rest state is `nil`, flag-off `.browseNav`);
  the generic `onDismiss` catch-all never re-presents a sheet mid-mode.
- [ ] **A22** Modes are mutually exclusive: long-press during block-select/spot-placement/placement is a no-op.
- [ ] **A23** No SwiftUI state write occurs per frame (instrument: write count during a 3 s pan is
  bounded by blockface changes + 1 settle).
- [ ] **A24** All camera mutation is outside `updateUIView` (#31 invariant, reviewed explicitly).

Legibility and ergonomics
- [ ] **A25** Contrast ratios (card text, chip, button, needle vs both basemaps) computed and recorded
  in the PR; card is fully opaque; no alpha < 1 on needle, ghost, highlight or card.
- [ ] **A26** All tappable controls >= 44 pt; primary >= 56 pt; Cancel and locate 48 pt.
- [ ] **A27** No "avoid", "ticket", "fine", "evasion" or "dodge" copy anywhere in new strings.
- [ ] **A28** Arrival prompt (W8.5d) and in-drive Park here diff to zero lines; existing arrival tests
  pass unmodified.

**Live-UI smoke (Mac gate, hard requirement — `HANDOFF.md:74` precedent):** (1) flag-on cold launch
shows no new chrome; (2) long-press mid-block, drag across the centreline both ways, watch the
highlight and card switch sides once with no flicker; (3) long-press in a building lot -> "No curb
here" + arrow chip; (4) park the car, confirm My Car shows the right side and "Free until" text;
(5) pill -> Next -> Enforcement -> submit, verify coordinate on the map matches the placed curb;
(6) Spot open from placement; (7) Cancel from each entry restores the camera; (8) rotate/pinch
mid-mode; (9) flag-on ambient (tilted) screen -> long-press -> exit -> tilt restored, no GPS
escalation (status-bar location arrow does not stay on); (10) flag-off regression: legacy dialog
and card behave as before; (11) simulate arrival prompt in Drive Mode — unchanged.
Kevin's separate daylight/outdoor check (A.5) is a flip prerequisite.

### A.12 Sizing

A1 ~0.5 session; A2 ~1-1.5; A3 ~1-1.5; C ~0.5; B ~0.5 (parallel); QA 1.5-2 passes. Engineering ~3.5-4
sessions; wall-clock ~3-3.5 with A1 || A2 || B first. This is **larger than the original S2 (~1-1.5
sessions for the risky rewire)** because it adds a new gesture-driven camera mode; the offset is that
it ships dark and S2's risk shrinks. Cutting scope if needed, in order: drop C (the extra taps are
harmless), drop Path B routing (keep `ParkConfirmView`), drop the arrow chip and haptic tick, drop
the settle nudge (ghost+tether alone still reads). Do NOT cut hysteresis, pitch flatten, the opaque
card, or the flag.

### A.13 Out-of-scope follow-ups (noticed, punted)

1. **Arrival prompt saves a car with no segment** (`detectedSegmentID: nil, detectedSide: nil`,
   `ContentView.swift:1743-1757`). A headless `CurbSnapIndex.resolve` at commit time (no UI, no extra
   tap) would fill street+side and put the car on the curb. Left out: touches the driving safety flow
   and deserves its own flagged slice.
2. **Haptic tick on blockface change** and the arrow-to-nearest-curb chip — nice-to-have, cut first.
3. **Address/POI search that lands in placement mode** ("take me to 123 Spring St and let me place")
   — natural fit with `BrowseSearchAreaView`; separate spec.
4. **Per-side "can I park here at all" shading in placement** (e.g. grey hydrant zones) — needs data
   we do not have in tiles.
5. **Deleting legacy long-press paths** after the flag flips (A.9).
6. **Using the snapped coordinate to dedupe Regulars/community pins on the same blockface** — backend
   concern, not placement.
