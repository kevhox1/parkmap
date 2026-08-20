# FT-20 — Browse-Mode Bottom Sheet Navigation

> ## ✅ KEVIN'S RULINGS ON §0's OPEN QUESTIONS — 2026-08-19 (settled)
>
> **OQ-1 — sheet mechanism: AGREED, use the system `.sheet` with `.presentationBackgroundInteraction`.**
> Boring technology on the riskiest file in the project. No hand-rolled draggable sheet.
>
> **OQ-2 — Park Until: keep it top-right**, as a third floating map control beside Locate and
> Find-my-car. The sheet's action list stays exactly three (Settings / Drive-Cruise / Parking 101).
>
> **OQ-3 — detent: use a CUSTOM detent, not `.medium`.** Kevin: *"if we do medium then can it be
> pushed down to give more room of the map?"* Yes — SwiftUI supports custom height/fraction detents.
> Size it to exactly the search bar plus three action rows and no more. **Rationale worth carrying:
> unlike Apple Maps, where the sheet is the main event and the map is context, WePark's map IS the
> product** — the coloured curbs are the entire reason to open the app. The sheet takes the minimum
> space that still does its job.
>
> **OQ-4 — "parking near here" in the place state: INCLUDE IT.** Kevin: *"Oh then yes. I want that."*
> A one-line summary of parking conditions around a searched destination (e.g. "Mostly metered · 2 free
> blocks within a 3-min walk"), computed by reusing `pickBestParkingAwareRoute`'s existing scan-and-score
> logic against a point instead of a route.
>
> **⚠️ OQ-4 is the first step of an already-specced flagship feature — build it with that in mind.**
> Kevin's follow-up: *"the way it works in the future is to score parking nearby and direct the driver
> through the optimal path (to find parking) nearby the target destination."* That is already captured in
> **`docs/smart-parking-route-2.0-concept.md`** (his own idea, 2026-06-09 — coverage + durability
> objectives, detour budget) and in **`docs/drive-mode-scope-spec.md`'s patrol mode (W8.5e–i)**, which
> ports the PWA's working `generateParkingRoute` greedy traversal (`index.html:7038`). **So OQ-4's scoring
> should be factored as reusable logic, not a one-off chip** — it is the same scoring the routing feature
> will need, applied to a point rather than a path. Getting it in front of Kevin early also validates
> whether the scoring *feels* right before navigation is built on top of it.
> Dependency reminder from the concept doc: the full feature waits on the supabase-swift realtime
> foundation, and Realtime Stream B is specced but not yet built.



**Status:** SPEC — awaiting Kevin's answers to §0 Open Questions before code starts.
**Owner:** Tech Lead (this spec) → `@designer` (interaction review) → `@ios-engineer` (build), in that order.
**Trigger:** Kevin, `docs/field-testing-log.md` FT-20 (backburnered 2026-08-18, unblocked for spec work
2026-08-19 by explicit request). Original ask: *"everything is on the bottom bar that swipes up... Can
there be a search icon where someone can put in an address and then underneath that the drive mode
buttons, settings, park school etc?"*
**Scope:** Browse-mode chrome only. **Drive Mode's FT-18 Bottom Dock is unchanged, full stop** — Kevin
validated it on-device 2026-08-18 (`docs/design/ft18-drive-mode-layout.md`, "✅ ON-DEVICE VALIDATION") and
explicitly wants it kept. This spec's only interaction with Drive Mode is the *boundary* — what happens to
the new sheet the instant `driveModeActive` flips, in either direction.
**Explicitly NOT in this spec:** dark mode. Kevin wants that as a separate, parallel item, done first. Where
a layout choice here would make a later dark-mode pass harder, it's called out as a constraint (see §8).
**Extends / touches:** `ios/WePark/WePark/ContentView.swift` (the single most contended file in the
project — see §9 sizing), `ios/WePark/WePark/Views/DriveModeDestinationView.swift` (content relocates out
of this file's `.fullScreenCover` presentation), `docs/w8.5b-destination-routing-spec.md` (§0 OQ-2/OQ-3,
superseded — see §3.2), `docs/ft15-tf215-temporary-block-restrictions-spec.md` §4.2 (block tap-select —
the sheet must get out of its way, see §5), `docs/design/ft18-drive-mode-layout.md` (Bottom Dock —
unchanged, boundary only, see §6).

---

## §0 — Open Questions for Kevin (read before code starts)

**One decision from the original brief is already resolved — noting it here so it isn't re-litigated.**
Kevin ruled 2026-08-19: search does **not** auto-enter Drive Mode. It follows Apple Maps — search → show
the place → user taps **Go** → Drive Mode begins. The conceptual clarification survives: entering Drive
Mode *with* a destination is the search→place→Go path; the explicit Drive/Cruise button in the sheet means
*cruise* (drive with no destination). See §3 for how this is spec'd.

Four real open questions remain, ordered by how much they block engineering:

**OQ-1: Sheet presentation mechanism — reuse the existing system-`.sheet` pattern, or build a custom
in-tree draggable sheet?** This is the single decision the rest of the estimate hinges on (§4.1). My
recommendation is the system-sheet route (a new `ActiveSheet.browseNav` case, `.presentationDetents` +
`.presentationBackgroundInteraction(.enabled)`, iOS 16.4+ API built for exactly this "Maps-style
persistent sheet" use case) — but it requires a mechanical change to every existing sheet's dismiss
handler (§4.1's "return to `.browseNav`, not `nil`" change) and it's a genuinely new pattern for this
codebase, so I want it confirmed rather than assumed given `ContentView.swift`'s regression history.

**OQ-2: Where does Park Until live?** Decision 4 in the original brief lists exactly three things the
pulled-up sheet reveals — Settings, Drive/Cruise Mode, Parking 101 — and calls it "the whole list." Park
Until (`ios/WePark/WePark/ContentView.swift:1572–1582`, the `clock.fill` toolbar button) is a real, shipped,
frequently-used feature with no assigned home in that list. I'm not comfortable silently picking its
placement myself — see §5.3 for the candidate answers and my recommendation (a third floating icon next to
Locate/Find-my-car, same "map display control, not navigation" framing Kevin used to justify those two
staying out of the sheet).

**OQ-3: Sheet default detent on cold launch and on every return from Drive Mode — peek, or medium?** Peek
matches "clean, map-first" and Apple Maps' own default. Medium surfaces the 3-item list without a drag,
which is arguably friendlier for a first-time user who doesn't know to swipe. Recommend **peek** — it's
the literal reading of "everything is on the bottom bar that *swipes up*," and Settings/Parking 101 are not
first-open actions.

**OQ-4: The "place" state's parking-context chip — ship a cheap version now, or defer entirely?** Kevin
separately noted he searches destinations partly to check parking nearby before committing, so this state
has value beyond "confirm and go." §3.2 proposes a cheap in-scope version (radius scan over already-loaded
segments, one summary line — "Parking near here: mostly free"). Confirm this is worth the ~0.5 session it
adds, or defer to a follow-up (§10).

---

## §0b — Design-review amendments (BINDING, 2026-08-19)

From `docs/design/ft20-bottom-sheet-review.md`. Kevin approved folding all six Significant findings
into the build rather than deferring them to a follow-up round. **These are spec, not suggestions.**
Owning stream in brackets.

- **S1 [Stream A] — the medium detent's 3-item list gets an explicit visual spec.** Build the rows as
  `List` rows matching `recentDestinationsList`'s anatomy verbatim
  (`DriveModeDestinationView.swift:269–362`, `List` + `Section`, `.listStyle(.insetGrouped)`) — SF
  Symbol leading icon + label. **Do NOT invent capsule/pill rows** borrowed from FT-18's Bottom Dock:
  that language is for floating chrome over a live map, and these rows live *inside* sheet content one
  scroll away from the suggestions list. Reuse `car.front.waves.right.fill` from the deleted
  `driveEntryButton`, plus `gearshape` and `questionmark.circle`.
- **S2 [Stream B] — "Parking near here" carries semantic colour.** Render the bucketed word
  ("mostly free" / "mixed" / "mostly restricted") in the matching **existing** `ParkingColors`
  green/amber/red — do not define new colours. Plain `.secondary` grey would break the app's own
  most-established convention, where those three colours already mean something specific everywhere
  else. Amends §3.2 and AC-10.
- **S3 [Stream C] — new AC-29a, mirroring AC-28 for Drive-Mode EXIT.** "The instant `driveModeActive`
  flips false, no frame shows both the outgoing Bottom Dock and the reappearing browse sheet." AC-28
  already guards entry; the mirror case was dropped, and transition-timing bugs are this file's
  documented failure mode (FT-17a, FT-18, W8.5c-polish), not static layout bugs.
- **S4 [Stream C] — new AC for the FT-15 block-select boundary.** Entering block-select overlaps
  *three* presentation animations (the `.confirmationDialog` dismissing, the browse sheet dismissing,
  `blockSelectBar` appearing) — see `ContentView.swift:2536–2546`. The very next user action is a
  precision multi-tap on the map, so a residual tap-intercepting overlay would make the first
  blockface selection silently miss. Either sequence `blockSelectModeActive = true` so it doesn't race
  the dialog's dismissal, or document a settling window and confirm the map ignores taps during it.
- **S5 [Stream B] — add `.scrollDismissesKeyboard(.interactively)`** to `suggestionsList` /
  `recentDestinationsList` when they relocate. §4.3's table says they move "verbatim"; this is the one
  addition. Removing the `NavigationStack`'s `Cancel` button is correct and matches Apple Maps, but
  **none of the existing sheets in this codebase set this modifier**, so the standard iOS
  scroll-to-dismiss gesture has no guarantee of working — a user who starts typing and changes their
  mind would get a stuck keyboard.
- **S6 [QA / Kevin's smoke, not code] — sunlight check.** When Kevin does his on-device pass, ask
  explicitly about the top-right rail and the sheet's peek/medium chrome **in direct sun**, not just
  indoors. Carry-over risk, not introduced by FT-20: TF2-18 logged a real sunlight-legibility problem,
  and the always-dark default (#83) shipped for *cleanliness* and was explicitly **not** a legibility
  fix. No simulator smoke can test this.

### §0c — CORRECTION to §9's work-stream table (2026-08-20, found during Stream B)

**§9 assigns "gut `DriveModeDestinationView.swift`" to Stream B. That is wrong given the actual serial
order (B → C), and Stream B correctly refused it.**

That file's `.fullScreenCover` (`driveModeDestinationCover` / `showDriveModeDestination` /
`driveEntryButton`) is **still the live destination-search entry path today** — Stream C is what
deletes it. Gutting it during Stream B would have stripped the `NavigationStack`/Cancel chrome out
from under a flow users can reach in the shipped app: a live regression, and the same class of
"correct for the end state, broken in the intermediate state" mistake that produced Stream A's trap
state. §9's table implicitly assumed B lands *after* C's cover deletion; it doesn't.

**What Stream B did instead:** left `DriveModeDestinationView.swift` at **zero diff** and built the
relocated content additively as `Views/BrowseSearchAreaView.swift`, reachable only through the gated
`.browseNav` sheet. It **reuses** `SearchCompleterDelegate`, `RecentDestinationsStore` and
`SearchTimeoutError` from the untouched file — only the SwiftUI view layer is duplicated, which is
unavoidable while two presentation contexts coexist.

**⚠️ STREAM C INHERITS THE CONSOLIDATION — this is now part of C's definition of done:**
1. Delete `driveModeDestinationCover`, `showDriveModeDestination`, and `driveEntryButton`.
2. Delete `DriveModeDestinationView.swift` once nothing references it.
3. Collapse the duplicated `onRouteReady` closure body — Stream B duplicated
   `driveModeDestinationCover`'s body (AC-11) rather than sharing it, because sharing would have
   required touching the still-live cover. One call site after C.
4. Do all of the above **in the same change that flips `ft20BrowseSheetEnabled`**, so there is never a
   build with two live search paths.

Leaving the duplication un-consolidated is the failure mode to watch: two search implementations that
drift apart is worse than either one alone.

---

**Estimate impact:** the reviewer judged S1–S6 to be spec-tightening rather than new surface area —
S3/S4/S6 add no code at all (ACs and a smoke question), and S2/S5 are one-liners. S1 is the only one
with real content, and specifying it *reduces* risk by removing an invent-it-yourself decision.
Treat 4.5–6.5 sessions as unchanged, with the spec's standing advice to budget a follow-up round.

---

## 1. Problem & user story

Browse-mode chrome grew feature-by-feature across nine months of shipped work (W5.1 recenter buttons → W7
gear/settings → W7.5 Park Until → FT-13 Parking 101 `?` → the combined Drive/Cruise `Menu` from W8.5b/CM-3)
and was never given a structural pass — FT-18 did exactly this for Drive Mode chrome in August, and Kevin's
reaction to the result ("I do like the new button design on drive mode") is the direct trigger for this
request: extend the same discipline to the mode he actually opens the app into.

Today's browse mode is two independent floating clusters — gear + `?` top-left, and four stacked icons
(Find me / Find my car / Park Until / combined Drive-entry `Menu`) top-right — plus whatever's pinned to
the bottom safe area (Park Until pill, first-launch Parking 101 banner). None of it is discoverable as one
system; a new user has no reason to know the `Menu` icon opens two different navigation modes with
different-length labels, or that the clock icon is a map filter and not a settings shortcut.

**User story:** *I open WePark. I see the map, clean, with a small search bar peeking up from the bottom.
I type an address — the sheet expands, shows suggestions and my recent spots. I tap one — the sheet shows
the place, how far it is, and a Go button. I tap Go — I'm driving. Or: I don't want a destination, I just
want to find parking near me — I swipe the sheet up, tap "Cruise," and I'm driving with no destination. Or:
I want to check my settings or re-read the Parking 101 guide — same swipe-up, same list.*

---

## 2. Scope — In / Out

**In:**
- A single persistent bottom sheet as browse mode's primary navigation surface, three detents (peek /
  medium / large — see §4.2).
- Search (relocated from `DriveModeDestinationView`'s `.fullScreenCover`) as the sheet's top element at
  every detent ≥ peek.
- The resolved-destination "place" state (§3.2) with a short, prominent **Go** button — this is the
  concrete answer to Kevin's search→place→Go ruling, and where the "button text too long" complaint (item
  3 of the FT-20 log entry) gets fixed for the destination path.
- Medium detent's 3-item list: Settings, Cruise Mode, Parking 101 — short labels, one control language.
- Locate and Find-my-car staying as floating map controls, top-right, outside the sheet (decision 5).
- Removing the gear button, `?` button, and the combined-entry `Menu` from their current floating
  positions — their functionality is absorbed into the sheet.
- Resolving Park Until's placement (OQ-2) and moving it there.
- The FT-15 block-select mode / sheet conflict (§5) — the "hard problem" this spec is required to solve,
  not hand-wave.
- The Drive Mode entry/exit boundary (§6) — the sheet must not fight FT-18's Bottom Dock or FT-17a's
  Recenter.

**Out (explicitly deferred, see §10):**
- Dark mode (separate, parallel, per Kevin's instruction).
- Any change to Drive Mode's active chrome (FT-18's Bottom Dock, `DriveModeBottomCard`, End control,
  Recenter — untouched).
- Rich parking-context UI in the "place" state beyond the cheap one-line summary in §3.2 (OQ-4).
- A real-device / real-motion accessibility pass on the custom drag interaction beyond the minimum parity
  bar in §7's AC list.
- FT-21 (curb-offset geometry) — unrelated, separately backburnered.

---

## 3. Product design — search, place, and the collapse of Drive-vs-Cruise

### 3.1 The terminology win, carried through

The app has had a genuine, load-bearing ambiguity between "Drive Mode" and "Cruise Mode" since W8.5b/CM-3
introduced the combined-entry `Menu` (`ContentView.swift:1611–1635`, options "Drive to a destination" /
"Find Parking nearby"). That ambiguity is visible in the code itself — `DriveModeStyle`
(`ContentView.swift:253–262`) already models exactly two states, `.destination` and `.cruise`, with a
comment explaining CM-3 added the enum *because* an earlier nil-based gate caused "guard-inversion bugs" —
and it shows up across several TF2 camera-entry bugs where destination-entry and cruise-entry shared a
camera path that neither fully owned (TF2-6, TF2-8, TF2-11, `docs/field-testing-log.md`).

Kevin's framing collapses it cleanly: **entering Drive Mode with a destination is the search→place→Go
path. The explicit button means cruise.** This spec carries that language forward literally — the sheet's
3rd item is labeled **"Cruise"** (not "Drive Mode," not a menu with two options), and it calls
`enterCruiseMode()` directly (`ContentView.swift:1885–1894`), the exact same function the old `Menu`'s
"Find Parking nearby" item already called. No new entry-path code; only the presentation UI around it
changes. The `Menu` itself is deleted — its two long labels ("Drive to a destination" / "Find Parking
nearby") are what made the toolbar buttons look wordy; removing the menu removes the problem at the root
rather than truncating the strings.

### 3.2 The "place" state is real UI, not a pass-through

Per Kevin's ruling, tapping a search result does not start driving. It resolves to a **place state**:

```
┌─────────────────────────────────────────────┐
│  ─────                                       │  ← grabber
│  🔍  350 5th Ave                          ✕  │  ← search field, now showing the resolved query
├─────────────────────────────────────────────┤
│  📍 Empire State Building                    │
│     350 5th Ave, New York, NY                │
│     1.4 mi away                              │
│     🅿️ Parking near here: mostly free         │  ← OQ-4, cheap version (see below)
│                                               │
│           ┌─────────────────────┐            │
│           │         Go          │            │  ← large, primary, thumb-reachable
│           └─────────────────────┘            │
└─────────────────────────────────────────────┘
```

This is a relocation of `DriveModeDestinationView`'s existing `startDriveSection`
(`DriveModeDestinationView.swift:366–402`), not a new invention — that view already has exactly this
state (`resolvedCoordinate != nil` → show a big "Start Drive" button, currently
`.font(.headline)` + `.frame(maxWidth: .infinity)` + `.padding(.vertical, 14)`,
`DriveModeDestinationView.swift:387–399`). The changes from what exists today:
- Renamed **"Go"** (was "Start Drive") — shorter, and reads correctly now that the button's meaning is
  unambiguous (there is no cruise option on this screen to distinguish it from).
- New: a distance line (`CLLocation.distance(from:)` against `userLocation`, same pattern
  `DriveModeBottomCard`'s distance indicator already uses for the destination chip, W8.5c-polish PR-1).
- New (OQ-4, in scope if confirmed): a one-line parking-context summary. Cheap version — radius scan
  (100m) over `tileLoader.segments` already resident in memory (the same segments array
  `pickBestParkingAwareRoute` already scores routes against, `RouteService.swift`), classify each nearby
  segment's `CurrentState` via the already-loaded `ParkingRulesEngine`, and bucket the result into
  mostly-free / mixed / mostly-restricted. No network call, no new service — reuses the exact haversine
  distance-search pattern W5's "Wrong street?" alternatives search already established
  (`ParkPinService`/`findCandidateSegments`). The richer version (highlight which nearby blocks are best,
  tie into Smart Move) is **out of scope**, flagged in §10.
- Everything else about `DriveModeDestinationView`'s existing behavior around this state is preserved
  verbatim (see §4.3 for the full "what's kept / what changes" accounting).

On **Go**, the exact same sequence `driveModeDestinationCover`'s `onRouteReady` closure runs today fires
(`ContentView.swift:776–784`): `driveModeStyle = .destination`, `activeRoute = route`,
`driveDestinationCoordinate = destination`, `driveModeActive = true`. No change to that state machine —
only the UI container that leads into it changes.

### 3.3 Auto-expand on search focus

Tapping the search field — visible even at peek height, since search is "the primary element" (decision
3) and must be reachable without a drag first — programmatically drives the sheet to **large** and focuses
the keyboard (`searchFieldFocused = true`, ported verbatim from
`DriveModeDestinationView.swift:180–185`'s `.onAppear` focus behavior). This matches Apple Maps' own
search-tap behavior and is the primary entry path most users will actually take, not an edge case — it
gets its own acceptance criterion (§7).

---

## 4. Architecture

### 4.1 Sheet presentation mechanism (OQ-1)

Two real options, weighed honestly because this codebase has no precedent for either and the choice
determines most of the estimate in §9.

**Option A — System `.sheet`, reused via a new `ActiveSheet.browseNav` case (recommended).**
`ActiveSheet` (`ContentView.swift:178–244`) already exists specifically to give every sheet in this app one
host and one dismiss mechanic — the W5.1 doc comment at the top of the file is explicit about why:
*"SwiftUI only supports a single .sheet() host per view... Collapsed three separate .sheet(item:) bindings
into one enum-driven ActiveSheet binding"* (`ContentView.swift:48–51`). Add `.browseNav` as a new case.
Configure it with:
```swift
// ⚠️ CORRECTED 2026-08-19 (design review B1). An earlier draft of this block used system
// `.medium` as the middle detent, contradicting OQ-3's ruling at the top of this file.
// DO NOT use `.medium` here. All 11 existing `.presentationDetents` call sites in
// ContentView.swift use `.medium`/`[.medium, .large]`, so copying the local convention is the
// easy mistake — and `.medium` is ~50% of the screen, which is precisely the "sheet eats the
// map" outcome Kevin rejected. WePark's map IS the product.

@State private var browseSheetMediumHeight: CGFloat = 260   // measured, see below
private let browseSheetPeekHeight: CGFloat = 96

.presentationDetents(
    [.height(browseSheetPeekHeight), .height(browseSheetMediumHeight), .large],
    selection: $sheetDetent
)
.presentationBackgroundInteraction(.enabled(upThrough: .height(browseSheetMediumHeight)))
.presentationDragIndicator(.visible)
.interactiveDismissDisabled(true)   // Apple Maps' sheet is never fully dismissible, only collapsible
```

**Both heights must be MEASURED, not hardcoded (design review B2).** The peek and medium values
above are starting points, not final numbers. Size the medium detent from the actual rendered
content — search field + exactly three rows + padding — and feed the measured value into
`.height(...)`, so the "search + three rows and no more" promise survives Dynamic Type instead of
silently breaking at accessibility text sizes. Peek must clear a full 44pt touch target plus the
grabber. Measure via `.onGeometryChange` (iOS 16+) or a `GeometryReader` background preference on
the content stack; clamp the result so a runaway text size can't drive the medium detent past
`.large`.
`.presentationBackgroundInteraction` is the iOS 16.4+ API Apple built for exactly this "Maps-style
persistent search sheet" pattern — this is the supported path, not a workaround. `.interactiveDismissDisabled`
keeps it from being swiped away to nothing, matching Apple Maps (there is always at least a peek).

The mechanical cost: `activeSheet` is currently a **transient** concept — every one of the ~12 existing
cases' `onDismiss` closures sets it to `nil` (`ContentView.swift:671–678`'s `.sheet(item: $activeSheet,
onDismiss: { activeSheet = nil })`). Under Option A, `.browseNav` is the browse-mode **rest state**, not
"nothing." Every existing case needs its dismiss target changed from `nil` to `activeSheet =
(driveModeActive || blockSelectModeActive) ? nil : .browseNav` — a small, mechanical, but real diff across
every sheet case, not a one-line change. This reuses proven infra (dismiss-then-present-new between two
`.sheet(item:)` values is already exercised today for the pin-detail transition,
`ContentView.swift:1097–1098`'s comment) rather than inventing a second presentation system.

**Option B — Custom in-tree draggable sheet (fallback).**
A new view (`DragGesture` + `.offset`, snap-to-nearest-of-3-detents via a pure velocity/position function —
the same "extract state logic as a pure, unit-testable function" discipline this file already uses for
`paddingForBannerState`/`shouldPauseFollow`/`recenterButtonStackVisible`). Avoids the "rest state, not
transient" conceptual blend of Option A entirely, and gives exact control over the peek height. **Real
cost, named plainly:** system `.sheet` content gets keyboard avoidance for free; a hand-rolled
overlay-positioned view does not — the sheet's own offset or inner padding has to be driven off
`NotificationCenter` keyboard-frame notifications, a genuinely fiddly piece of SwiftUI/UIKit interop that
inflates almost every hand-rolled bottom-sheet implementation people build. VoiceOver drag-to-resize is
also not free (system sheets already expose an adjustable grabber to VoiceOver; a custom `DragGesture`
needs an explicit `.accessibilityAdjustableAction` or equivalent button-based alternative built by hand).

**Recommendation: Option A.** It's the "boring technology" choice on the single file in this codebase with
the worst regression history, it reuses a pattern already proven safe here, and it's the API Apple shipped
specifically for this use case. Flagged as OQ-1 rather than silently decided because it's foundational and
there's zero precedent either way in this repo — I'd rather Kevin confirm before `@ios-engineer` spends a
day finding out `.presentationBackgroundInteraction` behaves unexpectedly on-device (it needs a smoke test
either way, same as every camera/overlay change in this file's history).

### 4.2 Detents and what's visible at each

| Detent | Height (approx) | Content | Map visible area |
|---|---|---|---|
| **Peek** | ~96pt | Search field only (with grabber above it) | Full map minus a thin strip at the very bottom — matches Apple Maps' collapsed state. |
| **Medium** | ~40% screen | Search field + 3-item list (Settings / Cruise / Parking 101), or (if `parkUntilMode` is active and OQ-2 resolves in favor of relocating it here — see §5.3) a Park Until status row | Top ~60% of map fully interactive; `.presentationBackgroundInteraction(.enabled(upThrough: .medium))` lets taps/pans reach the map above the sheet. |
| **Large** | ~90% screen | Search field (focused) + suggestions list or recent-destinations list, or the resolved "place" state (§3.2) | Map mostly covered — matches Apple Maps' own full-search state, where seeing the map isn't the point, seeing results is. |

Auto-transitions: peek→large on search-field tap (§3.3); large→peek is NOT automatic on Go — Go dismisses
the "place" content entirely (Drive Mode begins, the sheet is hidden per §6) so there's no detent to
return to until the user ends Drive Mode.

### 4.3 Does this replace `DriveModeDestinationView`? What's kept, what's lost.

**Replaces its presentation, relocates its content.** The `.fullScreenCover(isPresented:
$showDriveModeDestination)` (`ContentView.swift:428`, `:679`, `:769–786`) and the file's own
`NavigationStack` + `.toolbar { Cancel }` chrome (`DriveModeDestinationView.swift:146–178`) are removed —
a full-screen modal cover is exactly the "not a bottom sheet" presentation this spec exists to replace.
Everything else is relocated near-verbatim as sub-views inside the new sheet's large-detent content:

| Piece | Disposition |
|---|---|
| `searchField` (`:218–242`) | Kept verbatim, becomes the sheet's persistent top row at every detent. |
| `MKLocalSearchCompleter` + `SearchCompleterDelegate` (`:39–57`) | Kept verbatim — region-biasing (`completerDelegate.completer.region = currentRegion`) still works, the sheet lives above the same map. |
| `recentDestinationsList` / `RecentDestinationsStore` (`:269–302`) | Kept verbatim — shown at large detent when query is empty, same MRU/swipe-to-delete behavior. |
| `suggestionsList` (`:306–362`) | Kept verbatim — shown at large detent while typing. |
| `errorBanner` (`:246–265`) | Kept verbatim — same `MapboxRouteError` → friendly-message mapping (`:579–593`), same inline (not modal) presentation. |
| Out-of-coverage toast (`:551–555`, `ToastService.shared.show`) | Kept verbatim — `ToastHostView` is a separate top-level ZStack layer (`ContentView.swift:1289`), unaffected by which container search lives in. |
| Auth-gate spinner + denied alert (`:377–423`) | Kept verbatim — driven off `LocationService.authorizationStatus`, portable as-is. |
| `startDriveSection` (`:366–402`) | Becomes the "place" state (§3.2) — renamed button, new distance + parking-context lines, same underlying `onRouteReady` call. |
| `NavigationStack` + `Cancel` toolbar button (`:146–178`) | **Removed.** Not a modal anymore — dismissing "back to search" is just collapsing the sheet or clearing the query, no explicit Cancel needed. |

Nothing named above is lost. This is a genuine relocation, not a rebuild — but it is real refactor work,
not a zero-cost move (§9).

---

## 5. The hard problem — FT-15 block-select vs. an unobstructed map

**Decision: hide the sheet entirely (not peek) for the duration of block-select mode. Restore it exactly
where it was on Cancel or on the report sheet's dismiss.**

### 5.1 Why hide, not peek

Kevin's own framing offered three options: peek, a dedicated full-screen mode, or something better. Peek
is tempting because it sounds like "getting out of the way," but it doesn't — even the ~96pt peek height
sits in exactly the screen region where the nearest blockface's tap target lives, on a feature whose entire
job is precise, sequential multi-tap accuracy (`docs/ft15-tf215-temporary-block-restrictions-spec.md`
§4.2 step 3: "tapping any rendered blockface toggles it into/out of a `@State selectedBlockKeys`"). A
sliver of persistent chrome sitting over the one interaction the user is mid-task on is worse than no
chrome at all, not better — an accidental tap on the search field mid-selection would silently expand the
sheet over the map the user is trying to tap.

A dedicated full-screen block-select mode is unnecessary scope: block-select **already has** a working,
Kevin-un-contested bottom bar (`blockSelectBar`, `ContentView.swift:1813–1855` — summary label, "Both
curbs" toggle, Cancel/Continue) that ships today inside the exact same `bottomSafeAreaContent` VStack this
spec's sheet would otherwise occupy. Building a second, parallel "full-screen mode" would duplicate that
bar's job for no benefit.

**Hiding the sheet entirely is the precedent this file already uses for exactly this class of
conflict.** `ParkingGuidePromptBanner` is already excluded during block-select with language that applies
verbatim to the new sheet: *"a deliberate focused task the user is mid-way through"*
(`ContentView.swift:1495–1496`). The new sheet joins the existing mutual-exclusion list
(`driveModeActive` / `blockSelectModeActive` / `parkUntilMode` / `showParkingGuideBanner`) the same way —
`activeSheet` is force-set away from `.browseNav` (to `nil`, since Drive Mode isn't active either) the
instant `blockSelectModeActive` flips true, and restored to `.browseNav` when it flips back false via
either `cancelBlockSelectMode()` (`:2519`) or the report sheet's dismiss (`:2532–2533`). This requires zero
changes to `blockSelectBar`, `handleBlockSelectTap`, or the FT-15-shipped multi-segment highlight overlay
in `MapViewRepresentable.swift` — the sheet just gets out of the way, exactly as every other piece of
chrome in this file already knows how to do.

### 5.2 `BlockDetailView` / `ParkedCarDetailView` / the FT-15 restriction banner

**No conflict, by construction.** These are all existing `ActiveSheet` cases presented through the same
single `.sheet(item:)` host (`.blockDetail`, `.parkedCarDetail`, both `.presentationDetents([.medium,
.large])`). Under Option A (§4.1), tapping a block transitions `activeSheet` from `.browseNav` directly to
`.blockDetail(segment)` — the exact dismiss-then-present-new mechanism already proven for the
`PinDetailSheet` transition (`ContentView.swift:1097–1098`'s comment: *"SwiftUI's .sheet(item:) handles the
dismiss-then-present automatically"*). The FT-15 "Temporary restriction reported" banner
(`docs/ft15-tf215-temporary-block-restrictions-spec.md` §9.2) lives **inside** `BlockDetailView`'s and
`ParkedCarDetailView`'s content — it's unaffected by anything at the `ActiveSheet` container level.

One real, minor limitation, named honestly rather than hidden: blocks physically underneath the sheet's
chrome (at peek or medium) can't be tapped directly — the user has to pan the map or collapse the sheet
first. This is the same limitation Apple Maps itself has for POIs under its own sheet, and is not the
"hard problem" this section is required to solve (that's specifically about block-select's reliable
multi-tap sequence, resolved above by full hide) — it's an accepted, ordinary cost of any bottom-sheet
navigation surface.

### 5.3 Where does Park Until go? (OQ-2)

Not one of Kevin's three listed sheet items, and not naturally block-select's problem either, but it needs
a home for the app to stay coherent. Candidates:

- **(a) A third floating icon, top-right, next to Locate/Find-my-car (recommended).** Kevin's own
  reasoning for keeping Locate/Find-my-car out of the sheet — "they're map controls, not navigation" —
  applies just as well to Park Until: it's a display filter over the currently-visible map (recolors
  currently-loaded segments green/red against a target time), not a "where am I going / what do I want to
  do" navigation action. Lowest-disruption option — it's already a self-contained 44×44 icon button today
  (`ContentView.swift:1572–1582`), just relocated a few pixels rather than redesigned.
- **(b) A 4th item in the sheet's medium list**, contradicting Kevin's explicit "that's the whole list."
  Not recommended without him re-opening that ruling.
- **(c) Folded into Settings** as a sub-screen entry. Adds a tap to a currently one-tap-from-toolbar
  feature; demotes a frequently-used filter.

Recommend (a). Flagged as OQ-2 rather than assumed.

---

## 6. Interaction with FT-18's Bottom Dock at the mode boundary

**Hard boundary, stated up front: this spec does not modify `MapViewRepresentable.swift`'s gesture code,
`recenterDriveMode()`, `endDriveControl`, `recenterRow`, or any other piece of FT-18/FT-17a's Drive Mode
chrome.** Both are Kevin-validated on-device and this spec's job is to not touch them, not to re-verify
them.

**Entering Drive Mode (via Go from the "place" state, or via the sheet's Cruise button):** the sheet must
disappear the instant `driveModeActive` flips true, using the same pattern the current
`recenterButtonStack`/`endDriveControl` mutual exclusion already uses at the `mapZStack` call site
(`ContentView.swift:1270–1279`: `if driveModeActive { endDriveControl } else if ... { recenterButtonStack
}`). Concretely: `activeSheet` (holding `.browseNav`) is set to `nil` in the same
`.onChange(of: driveModeActive)` → `handleDriveModeAndCamera(active)` handler
(`ContentView.swift:1305`) that already force-clears block-select state on Drive Mode entry — this spec's
sheet-clearing joins that existing self-healing backstop rather than adding a second, parallel guard.
Any in-progress, un-submitted search query is discarded on this transition (a fresh browse session after a
drive is the common case; preserving stale search text across a drive session would be more confusing than
useful — low-stakes call, not an OQ).

**Exiting Drive Mode** (`endDriveMode()`, `ContentView.swift:1896` region): the sheet reappears at
**peek** (OQ-3's recommendation) — not wherever it was left, since the whole point of leaving it at peek
by default is a clean re-entry, and the user has just finished a session where any prior search state is
stale anyway.

**FT-17a's Recenter** (`recenterRow`, `ContentView.swift:1687–1699`, pan/pinch pause-and-resume) is
entirely inside the Drive-Mode-active branch of `bottomSafeAreaContent` — this spec's sheet is hidden
throughout Drive Mode, so there is no code path where the two could interact. Verified by inspection, not
by re-testing FT-17a's own logic (out of scope, untouched).

---

## 7. Acceptance criteria

**Sheet mechanics**
1. Browse mode (not Drive Mode, not block-select mode) always shows the sheet at one of exactly 3 detents:
   peek, medium, large.
2. Sheet cannot be interactively dismissed to "nothing" (`.interactiveDismissDisabled` or equivalent) —
   there is always at least a peek state visible.
3. Default detent on cold launch and on every Drive-Mode-exit is peek (OQ-3, pending confirmation).
4. Search field is visible and tappable at every detent, including peek.
5. Tapping the search field at peek or medium programmatically transitions to large and focuses the
   keyboard.
6. Dragging the sheet snaps to the nearest of the 3 detents (system-sheet default behavior under Option A,
   or the equivalent pure snap function under Option B).

**Search, place, Go**
7. Typing in the search field shows live `MKLocalSearchCompleter` suggestions, matching current behavior.
8. Empty query shows the recent-destinations list (5 entries, MRU, swipe-to-delete), matching current
   behavior exactly.
9. Selecting a suggestion or a recent destination resolves to the "place" state: destination name,
   subtitle, distance from current location, and a Go button — no automatic Drive Mode entry.
10. If OQ-4 is confirmed in scope: the place state shows a one-line parking-context summary computed from
    already-loaded segments within 100m of the destination, with no network call.
11. Tapping Go fires the identical sequence `driveModeDestinationCover`'s `onRouteReady` fires today
    (`driveModeStyle = .destination`, `activeRoute`, `driveDestinationCoordinate`,
    `driveModeActive = true`) and the sheet disappears per §6.
12. `MapboxRouteError` cases render via the same inline (non-modal) error banner content and copy as today.
13. Destinations outside Manhattan coverage (`AppConstants.isInManhattanCoverage`) still show the existing
    out-of-coverage toast.
14. Clearing the search field returns to the recent-destinations list and clears any resolved place state.

**Medium-detent list**
15. Medium detent shows exactly the items resolved by OQ-2 plus Settings / Cruise / Parking 101 — no menu,
    no multi-line labels.
16. Tapping "Settings" opens the existing `ActiveSheet.settings` sheet, unchanged.
17. Tapping "Parking 101" opens the existing `ActiveSheet.parkingGuide` sheet, unchanged.
18. Tapping "Cruise" calls `enterCruiseMode()` directly — no intermediate menu — and Drive Mode begins
    exactly as it does today via that function.

**Removed / relocated chrome**
19. The gear button and `?` button no longer render as independent floating controls in browse mode — both
    are reachable only via the sheet's medium-detent list.
20. The combined Drive/Cruise `Menu` (`driveEntryButton`) is deleted; its two former options are now
    reached via search (destination) and the Cruise list item (no destination), never a menu.
21. Locate and Find-my-car remain floating, top-right, outside the sheet, unaffected by this spec (decision
    5) — Find-my-car's visibility rule (only when `parkPinService.parkedCar != nil`) is unchanged.
22. Park Until's relocated entry point (per OQ-2's resolution) preserves 100% of its current filter
    behavior (`parkUntilMode`, `ParkUntilPill`, stale-target clearing) — only its toolbar position changes.

**FT-15 boundary (the hard problem)**
23. Entering block-select mode (`blockSelectModeActive = true`) hides the sheet entirely — no peek, no
    partial visibility.
24. `blockSelectBar` renders exactly as it does today, unmodified, with the sheet gone from the bottom
    safe area.
25. Exiting block-select mode (Cancel, or the report sheet's dismiss) restores the sheet to `.browseNav` at
    whatever detent it was at before block-select was entered.
26. Tapping a block outside block-select mode still opens `BlockDetailView` via the existing
    `ActiveSheet.blockDetail` case, unaffected by the new sheet's presence at any detent.
27. The FT-15 "Temporary restriction reported" banner inside `BlockDetailView`/`ParkedCarDetailView`
    renders unchanged.

**Drive Mode boundary**
28. The instant `driveModeActive` flips true (from Go or from Cruise), the browse sheet disappears — no
    frame where both it and FT-18's Bottom Dock are simultaneously visible.
29. The instant `driveModeActive` flips false, the browse sheet reappears at peek.
30. No change to any file under `MapViewRepresentable.swift`'s gesture-handling code, `recenterDriveMode()`,
    `endDriveControl`, or `recenterRow` — diffed and confirmed zero touches to those symbols before merge
    (same "architecture verified" gate FT-18's and FT-15's own QA passes used).
31. Kevin's FT-17a on-device validation ("pinch → icon every time, tap → recenters immediately") is
    unaffected — verified by the zero-touch guarantee in AC-30, not re-tested from scratch.

**Non-goals held**
32. No hardcoded light-mode-only colors introduced — sheet chrome uses `.regularMaterial`/system
    background materials and semantic colors only, matching existing app-wide convention (§8).
33. No change to any Drive-Mode-active visual element (chip colors, `DriveModeBottomCard`, approach strip).

**Accessibility (minimum bar for this slice)**
34. The sheet's grabber/drag affordance exposes a VoiceOver-operable alternative to move between detents
    (system-sheet adjustable action under Option A, or an explicit accessibility action under Option B) —
    dragging alone is not sufficient.
35. Every relocated control (search field, Go button, 3 list items) carries the same `accessibilityLabel`/
    `accessibilityHint` content it has today, ported not dropped.

---

## 8. Dark-mode dependency note (not spec'd here)

Per Kevin's instruction, dark mode is out of scope for this spec and is being handled as a separate,
parallel, first-priority item. One layout dependency worth flagging now rather than discovering later:
this spec's sheet should use system semantic materials (`.regularMaterial`, `.ultraThinMaterial`,
`Color(.systemBackground)`, etc.) exclusively, never a hardcoded light-only fill — this is already this
file's convention everywhere (gear button, recenter buttons, End control all use `.regularMaterial`) and
costs nothing extra to follow here, but it's the one thing that would make the dark-mode pass harder if
skipped.

---

## 9. Work streams

| Stream | Owner | Files | Depends on | Parallel? |
|---|---|---|---|---|
| **Design review** | `@designer` | Reviews this spec's §3–§6 (wireframes, detent table, OQ-2/OQ-4 recommendations) before code starts — same "catch it before TestFlight" role FT-18 played. | This spec, Kevin's OQ answers | Runs first, blocks nothing else once complete — short, single pass. |
| **A — Sheet container** | `@ios-engineer` | New `Views/BrowseNavigationSheet.swift` (or, under Option A, the `ActiveSheet.browseNav` case + its `.presentationDetents`/`.presentationBackgroundInteraction` config, plus the mechanical "dismiss → `.browseNav` not `nil`" change across existing cases) | Design review, OQ-1 answer | Can start immediately once OQ-1 is answered; buildable/testable against a stub content view before Stream B lands. |
| **B — Search/place relocation** | `@ios-engineer` | `Views/DriveModeDestinationView.swift` (gutted: `NavigationStack`/toolbar removed, remaining sub-views relocated into the sheet's content), new place-state view with distance + OQ-4 parking-context chip | Stream A's public interface (can be stubbed early), OQ-4 answer | Serializes after Stream A's container exists; internal logic can be drafted in parallel against the stub. |
| **C — ContentView integration** | `@ios-engineer` | `ContentView.swift` — mount the sheet, delete `gearButtonOverlay`/`driveEntryButton`/the old `.fullScreenCover`, relocate Park Until per OQ-2, wire the Drive-Mode-boundary hide/show (§6), wire the block-select hide/restore (§5.1) | A + B both land | Serial — highest-risk stream, single PR, mandatory live-UI-smoke gate before merge (same discipline as every prior `ContentView.swift`/`MapViewRepresentable.swift` change since the #31 saga). |
| **QA** | `@qa-verifier` | Full AC pass across §7, explicit architecture-diff check for AC-30 | C merged | Serial, per TEAM.md invariant. Expect 2 passes given this file's history (FT-18, FT-15, FT-17a all needed at least one follow-up round). |

**Parallel group 1:** Design review can start the moment Kevin answers OQ-1/OQ-2/OQ-4 (or even before, if
he's comfortable reviewing against the recommendations). Stream A can start alongside it once OQ-1 lands.
**Serial tail:** B → C is unavoidable — B's content has nowhere to live until A's container exists, and C
is ContentView surgery that cannot be parallelized against another concurrent ContentView change (this file
is currently mid-recovery from three serialized changes — FT-17a, FT-18, FT-15 — landed one after another
for exactly this reason).

---

## 10. Out-of-scope follow-ups (named, not dropped)

- **Rich parking-context in the "place" state** (highlighting specific nearby blocks, Smart-Move-style
  ranking) — the cheap one-line version in §3.2/OQ-4 is the ceiling for this slice; the richer version is
  real, valuable, future work.
- **A11y pass on the drag interaction under real VoiceOver + real motion** — AC-34/35 set a minimum bar;
  a dedicated a11y review (matching the W4 "VoiceOver swipe-through-blocks" precedent already deferred to
  post-MVP) is a reasonable follow-up once the sheet ships and stabilizes.
- **Search history beyond the existing 5-entry recent-destinations list** — unchanged from today, not
  revisited here.
- **Reconciling this sheet's search with the FT-15 report flow's own address-adjacent UI** (if any future
  work adds address search to the block-restriction report) — no such UI exists today, noted only so it
  isn't accidentally duplicated later.
- **Dark mode itself** — separate, parallel, per Kevin's instruction (§8 notes the one dependency).

---

## 11. Sizing honesty

This is genuinely bigger than "extend FT-18's chrome cleanup to browse mode" sounds, for three compounding
reasons, and I'd rather say so now than have Kevin schedule off an optimistic number:

1. **It's a first-of-its-kind component for this codebase**, not a rearrangement of existing buttons. FT-18
   moved existing controls into a new layout; this spec introduces a persistent, non-modal, multi-detent
   sheet — a new interaction primitive, with real (if Option-A-mitigated) cost in keyboard avoidance,
   accessibility, and getting the mechanical `ActiveSheet` "rest state" change right across ~12 existing
   cases.
2. **It requires real refactor work on `DriveModeDestinationView.swift`**, not a cut-and-paste — its
   `NavigationStack`/toolbar/full-screen-cover chrome has to come out while every sub-view's actual logic
   (completer, recents, error banner, auth gate, out-of-coverage toast) is preserved exactly.
3. **It lands in `ContentView.swift`**, which just absorbed three serialized changes (FT-17a, FT-18, FT-15)
   specifically because of file contention and a documented same-day merge-then-revert history
   (`docs/HANDOFF.md`'s W8.5c-polish entry). The mandatory live-UI-smoke gate this file now requires is a
   real, valuable process cost, not paperwork — it caught the F1–F4 bugs FT-18 fixed and the region-sync
   regression FT-17a fixed. It also means this cannot be parallelized against any other concurrent
   ContentView change.

**Estimate: 4.5–6.5 iOS engineering sessions** (Stream A ~1, Stream B ~1.5, Stream C ~1.5–2, QA ~1–1.5
across 2 passes), plus the design review pass up front. This is comparable to or larger than FT-15's own
"iOS 4–6 sessions" sizing for a full new backend-to-render primitive — not because this spec has as many
moving architectural parts, but because it touches the same worst-case file with a genuinely novel UI
component. Given this project's own recent lesson (an SPM estimate given as "a few hours" that was really
2.5–3.5 sessions), and given that nearly every Drive-Mode-chrome change to date has needed at least one
follow-up round after Kevin's on-device smoke (FT-17a's two follow-on defects, FT-18's own trilogy,
W8.5c-polish's revert-and-relaunch), **I'd budget for a follow-up round beyond the 4.5–6.5 above, not treat
that number as the finish line.**

---

## 12. Explicitly flagged as bad ideas

- **Silently deciding Park Until's placement** rather than surfacing OQ-2. Decision 4's "that's the whole
  list" is Kevin's own words; treating a real, shipped feature as simply gone would be a worse mistake than
  asking.
- **Shipping the "place" state as a bare confirmation speed bump** (destination name + Go, nothing else).
  Kevin explicitly said this state has value beyond confirmation — building it as a pass-through would
  contradict his own stated reasoning for wanting search→place→Go over instant-drive in the first place.
- **Reusing `DriveModeDestinationView`'s `NavigationStack` + `.fullScreenCover` wrapper "for speed."** This
  is the exact presentation model (full-screen, modal, covers the map) Kevin is asking to move away from.
  Keeping it and just re-skinning it inside a "sheet" would not deliver the thing he asked for.
- **A dedicated full-screen block-select mode** (one of Kevin's own three offered options) — rejected in
  favor of full-hide (§5.1) because the existing `blockSelectBar` already solves this without any new
  screen, and a second parallel full-screen mode would duplicate its job.
- **Peeking (rather than hiding) the sheet during block-select** — the other offered option, rejected for
  the same reason: even the peek height sits over live tap targets on a feature whose entire value is
  precise tap sequencing.
- **Doing dark mode "while we're in here."** Explicitly out of scope per Kevin's instruction — resist the
  temptation even though this spec's colors would be easy to touch while already editing these files.
- **Treating Option A vs Option B (§4.1) as a coin flip.** It's the single most consequential engineering
  decision in this spec and deserves Kevin's explicit sign-off, not a default.
