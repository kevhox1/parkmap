# Long-press (and pill) as the universal "plant anything" entry — execution spec

**Supersedes:** `docs/open-items.md` #118 (tap-to-reposition, still `MERGE-PENDING-MAC-GATE`,
**not yet merged** — see §6) and #22 (the original "report flow: tap-to-place" spec,
`docs/report-tap-to-place-spec.md`, which #118 implemented). Both files are kept for history,
not deleted. **Does NOT supersede** #121 (curb-snap-on-display) — orthogonal, independent,
should proceed on its own schedule. **Does fold in / retire** #17b's target (the legacy
three-button `confirmationDialog` that #17b was patching is deleted outright by this spec, not
patched further).

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
