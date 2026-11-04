# First-run onboarding — design spec

**Status:** Design spec for @ios-engineer. Commissioned by `docs/open-items.md` #41, triggered by
Kevin's build-25 first-boot reaction (2026-11-04): *"I did see some haptic feedback and like intro
pages, but they weren't as extensive as the ones I had hoped that would really tell the story of
onboarding."* Designs against the FINAL, signed-off minimal ambient layout
(`docs/design/goal-first-ambient-design.md` Addendum 3: driving-look launch, Search+More rail,
Start Driving bar, three goal tiles) and `docs/drive-mode-default-spec.md` §0.1/§0.2 (no-nag, never
block the map, the one-shot `LocationPrimingCard`).
**Reference:** Kevin's liked example is Makeway's onboarding — 2-3 full-screen story cards (big
headline, one-sentence body, custom illustration, progress bars, Continue/Skip) → a floating
"welcome" card over the live map ("Show me around"/Skip) → a replayable multi-step tutorial from the
menu. This spec builds WePark's version of all three tiers, reusing our own existing pieces
(`LocationPrimingCard`, `ParkingGuideView`/Parking 101, the first-use placement hint pill) rather than
inventing parallel ones.
**Owner:** @designer.
**Does not relitigate:** the goal-first copy/icons (`goal-first-ambient-design.md` §1, Addenda 2-3) or
the curb-pin placement mode (`docs/design/curb-pin-placement-design.md`) — this spec only references
their final shapes as coach-mark targets.

---

## 0. The three tiers, at a glance

| Tier | What | When | New or reused |
|---|---|---|---|
| 1 | 3 full-screen story cards | Cold launch, before the live map is ever shown | New — `OnboardingStoryView.swift` |
| 2 | `LocationPrimingCard` | First home-screen render, only if `.notDetermined` | **Reused, unchanged, kept separate from Tier 1** — see §1.4 |
| 3 | 3 anchored coach marks over the real map | Right after Tier 1 (or immediately for upgrading users, §4.2) | New — `OnboardingCoachOverlay.swift` |
| — | Parking 101 (`ParkingGuideView`) | On demand, from More | **Unchanged** — stays the deep lesson, not touched by this spec |
| — | Replay | "How WePark works" row in More | New row, reuses Tier 1 + Tier 3 views verbatim |

Sequencing is strict and matches the task's ordering constraint: **story cards never request a
permission, full stop.** `LocationPrimingCard` only appears after Tier 1 is dismissed, on the live map,
exactly as it does today (§0.2 of the drive-mode spec, untouched). Coach marks run after that.

---

## 1. The story arc — 3 full-screen cards, pre-map

### 1.1 The story we're telling a zero-context NYC street parker

Not "here are our features." The arc is: **here's the actual problem → here's the one thing we ask
you → here's what you get for answering it.** Each card does exactly one job; none of them mention a
specific button by name (that's the coach layer's job, Tier 3) — these cards sell the *idea*, the
coach marks teach the *controls*.

### 1.2 Exact copy, per card

**Card 1 of 3 — the problem**
> ## Parking here is a game you play twice a week.
> Street cleaning swaps sides on a schedule — park on the wrong one, and you're moving the car for no
> reason.

**Card 2 of 3 — the ask**
> ## Tell us what you need.
> Overnight, a few hours, or days without moving it — pick one, and that's the only question the map
> answers.

**Card 3 of 3 — the payoff**
> ## Drive, and the map does the thinking.
> Everything simplifies to two colors — green means you're covered, red means you'll have to move it.

**AC-31 check:** no "avoid/ticket/fine/dodge/evasion" anywhere above — the worst-case language used is
"moving the car," which is the same honest vocabulary already locked into the goal tiles' own
sub-labels ("Won't need to move it"). Keeping this vocabulary identical across the story cards, the
goal tiles, and the coach marks is deliberate — a word a user reads on card 1 should mean the exact
same thing when they see it again on the real button three seconds later.

### 1.3 Illustration direction

Per the brief: line art over dark, **our hero visual is a real curb line, not a generic car or person**
— drawn in code with SwiftUI `Path`/`Capsule` shapes using the actual `ParkingColors` constants (same
file curb-pin-placement-design.md cites), not commissioned raster assets. This means zero asset
pipeline, free Dark Mode correctness (the app is dark-forced anyway), and the illustrations literally
foreshadow what the user is about to see on the real map.

| Card | Illustration | Build |
|---|---|---|
| 1 | Two short curb-line segments side by side (a street's two sides), left `ParkingColors.freeComfortably` (green), right `ParkingColors.restrictedNow` (red), with a thin gutter line between them and two small day labels underneath ("Mon" / "Tue") — the literal ASP side-swap, drawn as data. | Code-drawn `Capsule` pair, no asset. |
| 2 | Three plain-outline circles in a row, each holding one of the real goal glyphs at full size (`moon.stars.fill`, `hourglass`, `parkingsign.circle.fill`) — white stroke only, no fill, nothing selected yet, because the story is "you get to pick," not "here's the answer." | SF Symbols in outline-stroke circles. |
| 3 | A small tilted trapezoid (the exact driving-look camera framing from Addendum 3 A3.6) containing 4-5 short curb-line segments, binary green/red only (not the 5-color palette) — this is literally what the live map will look like 2 taps later. | Code-drawn trapezoid mask + `Capsule` segments. |

Illustration container: fixed aspect, occupies the top ~45% of the card, minimum height floor 160pt so
it never collapses to nothing at large Dynamic Type (§1.6).

### 1.4 LocationPrimingCard placement — KEEP SEPARATE, do not merge as a 4th card

**Recommendation: keep it exactly where §0.2 already puts it — after the story deck, floating over the
live map, not folded into the card sequence.** Three reasons:

1. **Different risk class.** The three story cards are inert — zero side effects, pure narrative.
   `LocationPrimingCard`'s "Allow" button fires the real system permission dialog. Merging it into the
   Continue/Skip pacing of a story deck means a system-level interruption can pop up mid-"story,"
   which breaks the rhythm Kevin explicitly liked (he called out the intro *pages* as a positive) and
   risks reading as a bait-and-switch — three slides building a narrative, then slide four is actually
   an OS permission prompt in disguise.
2. **Trigger-condition mismatch.** §0.2 gates the card on `authorizationStatus == .notDetermined` at
   first home-screen render. A reinstaller or anyone who granted location earlier would see nothing —
   fine as a floating card that simply doesn't appear, but awkward as a "4th card" that sometimes
   isn't there, which complicates the deck's own page count/progress-bar math for no benefit.
3. **It already maps 1:1 onto Makeway's own structure if left alone.** Story cards = their tier 1.
   `LocationPrimingCard` sits in the exact position their floating "welcome/show me around" card
   occupies — tier 2, over the live map — even though its content is different (permission ask, not a
   tour invite). Coach marks = their tier 3. Don't fight a structure that already fits.

No code change to `LocationPrimingCard` itself. The only new requirement is ordering: Tier 1 must fully
dismiss (`.fullScreenCover` closes) before the home screen's existing `.notDetermined` check runs — true
by construction, since that check already only fires on first home-screen render, and the home screen
doesn't render until the story cover is gone.

### 1.5 Mechanics — progress, Continue/Skip, haptics

- **Container:** `TabView(selection: $cardIndex) { ... }.tabViewStyle(.page(indexDisplayMode: .never))`
  — swipe forward/back both work (revisiting card 1 from card 2 is allowed, it's cheap and forgiving);
  system page dots are suppressed in favor of the custom progress bar below.
- **Progress indicator:** 3 segmented capsules, 4pt tall, equal width, 6pt gaps, 24pt horizontal
  margins, pinned at `safeTop + 16`. Current and past segments: `Color(.label)` full. Future segments:
  `Color(.label).opacity(0.2)`. Animates on `cardIndex` change (`.animation(reduceMotion ? nil :
  .default, value: cardIndex)`).
- **Skip:** top-trailing text button, `.footnote.weight(.semibold)`, label "Skip", sitting on a small
  `.ultraThinMaterial` capsule backing (same "material over unpredictable background" rule
  `goal-first-ambient-design.md` §2.4 already states for every floating control in this app — the
  illustration behind it is variable brightness). Tap target 44×44pt minimum even though the visible
  label is smaller. **Skip jumps straight to the end of the deck** (sets the one-shot flag, dismisses
  the cover) — it does not skip `LocationPrimingCard` or the coach marks, which are a different,
  independently-skippable tier (§2.4).
- **Continue button:** full-width capsule, `minHeight: 56`, 24pt horizontal margins, bottom margin
  `safeBottom + 16`. Fill `Color(.label)` (white in dark), label `Color(.systemBackground)` (black) —
  the exact monochrome idiom `curb-pin-placement-design.md` §3.2 row 5 already establishes for this
  app's primary buttons, so "chrome is monochrome, color is data" holds here too (no blue, no green —
  this screen has nothing to do with curb meaning yet). Label text: "Continue" on cards 1-2, **"Let's
  go"** on card 3 — the wording change signals this tap is the one that actually reveals the product,
  not just another page turn.
- **Haptic:** one light `.sensoryFeedback(.selection, trigger: cardIndex)` on every card transition
  (Continue tap or swipe) — this is the "haptic feedback" Kevin already said he liked; keep it and
  extend it to cover all 3 transitions, not just the ones that happened to ship in build 25.
- **Reduce Motion:** page transition becomes a crossfade, not a slide (`UIAccessibility.
  isReduceMotionEnabled`, observed live per the same pattern `curb-pin-placement-design.md` §1 uses).
  Progress-bar fill change is instant, no animation.
- **Dynamic Type (§1.6):** text styles throughout (`.largeTitle.weight(.bold)` headline, `.title3`
  body, `Color(.secondary)` is fine here — unlike the live map's outdoor-glare contrast problem, this
  is an indoor, brightness-controlled screen, so standard HIG hierarchy-by-weight-and-size applies).
  At AX sizes, the illustration container shrinks toward its 160pt floor and the text area becomes a
  `ScrollView` pinned above the fixed Continue button — same mechanism
  `curb-pin-placement-design.md` §3.5 already specifies for its own card (text rows scroll, action
  button never does).

---

## 2. The live coach layer — after the cards, on the real map

### 2.1 What it is NOT

Not a dimmed, modal, tap-to-advance overlay. §0.1 of the drive-mode spec is explicit: **never block the
map.** The coach layer is three small, non-blocking callout bubbles anchored to real controls — the map
stays fully interactive underneath and around them at all times. If a user taps the actual control a
bubble is explaining, that's a *better* outcome than reading the bubble (discovery beats exposition) —
the mark dismisses itself immediately and the sequence advances.

### 2.2 The three marks — target, copy, anchor

| # | Target (real control) | Copy | Anchor position |
|---|---|---|---|
| 1 | Goal tile row (`goalTileRow`, Addendum 3 A3.3) | **"Pick what you need."** / "The map will only show spots that match." | Bubble sits in the open map area directly above the Start Driving bar — the dock's own height (A3.3) leaves this space clear. Pointer arrow angles down past the bar to the tile row. A subtle pulsing outline ring (not a dim scrim) traces the tile row's own rounded-rect border; disabled under Reduce Motion in favor of a static ring. |
| 2 | The selected (Overnight) tile + the map's new green/red cast | **"Green means you're covered. Red means you'll have to move it."** | Bubble anchored just above the selected tile, pointer arrow pointing up into the map — bridges "you picked this" to "that's why the map looks like this now." No separate highlight needed on the map itself; the binary recolor from picking Overnight (already the default) is the demonstration. |
| 3 | The nearest real curb segment to the user's blue dot (reuse `CurbSnapIndex.nearbyBlockfaces`, already shipped for the VoiceOver curb list) | **"Tap any block to see why."** | Bubble anchored near that segment's screen position, short pointer + the same pulsing ring traced along that one polyline. If no segment is within range (sparse data, far zoom), fall back to anchoring near the map's visual center with the same copy — the lesson still holds generically. |

Copy reuses the exact "move it" vocabulary from the goal tiles and story cards (§1.2) on purpose — same
word, same meaning, every time the user encounters it.

### 2.3 Dismiss / skip / advance rules

- Each bubble carries one primary action — "Got it" on marks 1-2, **"Done"** on mark 3 — plus a
  persistent **"Skip"** text link in the same screen position on every mark (top-center, small
  `.ultraThinMaterial` capsule, same treatment as the story deck's Skip) so the exit is always in the
  same place.
- **Tapping the real control the bubble points at** dismisses that bubble immediately, lets the real
  action happen normally (e.g., the tile actually switches), and advances to the next mark after a
  short 300ms beat so the user sees the result land before the next bubble appears.
- **Panning or zooming the map** while a bubble is showing dismisses all remaining bubbles outright —
  same "disappears on its own once the user interacts" precedent the empty-map guard banner already
  sets (`goal-first-ambient-design.md` §3.2). The user is already exploring; don't fight that with more
  chrome.
- **One light `.sensoryFeedback(.selection)` per bubble's first appearance** (max 3 ever, matching the
  haptic discipline `curb-pin-placement-design.md` already holds this app to — confirmations, not
  decoration).
- **Gating — rest-posture only, never during a drive:** mount only when `!driveModeActive &&
  !blockSelectModeActive && !spotPlacementActive` — the identical exclusion list the ambient dock
  itself already uses (`goal-first-ambient-design.md` §6 item 4). If the user taps Start Driving while a
  bubble is showing, all bubbles dismiss immediately (escalating is a real, deliberate action; nothing
  should compete with it).
- **One-shot:** `hasSeenOnboardingCoach` (UserDefaults, `BackgroundNoteGate` convention — see §4).
  Never auto-replays. Reachable again only via More (§3).
- **Why this doesn't violate §0.1 despite being an "overlay":** nothing here is modal. No scrim, no
  trapped input, no forced order beyond "one bubble visible at a time," and any real interaction with
  the map or its controls — pan, zoom, tap a tile, tap Start Driving — immediately clears it. This is
  the bounded, one-time exception `docs/open-items.md` #41 itself describes ("skippable... honors
  §0.1") — call this out by name in the PR description, same as the project's #31 camera-mutation
  invariant gets called out in every Drive-Mode-adjacent PR.
- **Settle delay before mounting:** wait ~400ms after the ambient screen's own entry finishes (story
  cover dismissal for a fresh install, or app launch for an upgrading user, §4.2) before presenting
  mark 1 — avoids racing `anchorPreference` layout before the real dock/rail have settled, the same
  "wait for the map to stop" discipline the curb-pin placement mode's settle nudge already uses.

---

## 3. Replayability

### 3.1 "How WePark works" — new row in More

Add to the More sheet (`goal-first-ambient-design.md` Addendum 3, §A3.4) as a new row, grouped with the
other "learn" rows ahead of the settings/utility ones:

| # | Title | Subtitle | SF Symbol | Action |
|---|---|---|---|---|
| 2 | **How WePark works** | Replay the quick tour | `sparkles` | Dismiss More, present `OnboardingStoryView` as a `.fullScreenCover`; on its dismissal, mount `OnboardingCoachOverlay` once, same sequence as first-run. |
| 3 | What the colors mean | Green, red, and the rest | `questionmark.circle.fill` | *(existing row, renumbered)* |
| 4 | **Parking 101** | The full guide to NYC parking rules | `book.closed.fill` | Opens `ParkingGuideView`, unchanged content. |

(Row 1, Report, stays first — unchanged. Rows 5+ — Show all parking rules, Find my car, Park until a
set time — follow, renumbered, unchanged behavior.)

**This closes a real gap, not just a nice-to-have:** `docs/open-items.md` #37 ⑦ already flagged that
"Settings and Parking 101 are reachable flag-on only via Search" and asked whether More should get rows
for them before the flip. The answer here is yes for Parking 101 — it belongs next to its shallow
sibling ("How WePark works" is the quick tour; "Parking 101" is the deep lesson), not buried behind
Search.

### 3.2 Replay mechanics — independent of the one-shot state

A manual replay from More is a **separate code path from the automatic first-run gate**, not a reset of
it:
- Replay never reads or writes `hasSeenOnboardingStory` / `hasSeenOnboardingCoach` — it's a direct
  present, bypassing the gate entirely. Finishing or skipping a replay does not change what a *future*
  cold launch would show (there won't be one — the flags are already true for any device that can even
  reach More's new row, since More only exists on the already-onboarded ambient screen).
- Replay skips Tier 2 (`LocationPrimingCard`) entirely — permission state doesn't need re-explaining,
  and re-showing it would be a nag by definition (§0.1). The flow is: story cards → dismiss → coach
  marks → dismiss → back to the live map, exactly where More was opened from.
- More itself is only reachable from the ambient rest screen (not mounted during escalated Cruise), so
  "never during a drive" (§2.3) holds for replay by construction — **flag for @ios-engineer to verify**,
  not assumed.

### 3.3 Relationship to Parking 101 — unchanged, deliberately

Parking 101 (`ParkingGuideView`) is not touched, not merged, not shortened by this spec. "How WePark
works" teaches *which buttons do what* in under 15 seconds; Parking 101 teaches *how NYC parking
actually works* (ASP mechanics, meter hours, suspension days) at whatever depth a curious user wants.
Keeping them as two separate rows, two separate depths, is the correct shape — collapsing them into one
"onboarding" entry would force a shallow tour and a deep reference guide into the same pacing, which
serves neither.

---

## 4. State rules

### 4.1 New UserDefaults keys (BackgroundNoteGate convention — simple bool checks, no new model)

| Key | Set when | Checked by |
|---|---|---|
| `hasSeenOnboardingStory` | Tier 1's last Continue ("Let's go") or Skip tap | Gate for showing the story cover on cold launch |
| `hasSeenOnboardingCoach` | Coach mark 3's "Done" tap, or the coach-layer Skip tap | Gate for mounting the coach overlay |
| `hasLaunchedWeParkBefore` | Unconditionally, on the very first render of the app's root view — ever, regardless of any feature flag | The fresh-install vs. upgrading-user detector, §4.2 |

`LocationPrimingCard`'s own existing one-shot key is untouched.

### 4.2 Fresh install vs. upgrading user — recommendation: existing users get the coach layer only

**Recommendation (as the task invites, with justification): yes — existing installs get ONLY the
coach layer, once, right after they first land on the new ambient screen. They never see the 3
full-screen story cards.**

Why: the story cards sell *the idea* of WePark to someone who has never used it — "parking here is a
twice-a-week problem, here's our answer." An existing user already knows that; they installed the app
*because* they already believe it. What they genuinely haven't seen is the new minimal ambient layout
itself (`driveModeDefaultEnabled`'s flip is a real, user-facing rearrangement — new rail, new dock, new
tiles) — that's a legitimate "let me show you around the new furniture" moment, which is exactly what
the coach layer is for and the story cards are not.

**Mechanism — detect "existing" without any new assumption about prior app state:**

```
// First render of the app's root view, before any onboarding gate evaluates:
let isFreshInstall = !UserDefaults.standard.bool(forKey: "hasLaunchedWeParkBefore")
UserDefaults.standard.set(true, forKey: "hasLaunchedWeParkBefore")

if !isFreshInstall {
    // Existing install encountering this build for the first time:
    // pre-seed the story flag so cards never show, but leave the coach flag alone.
    if UserDefaults.standard.object(forKey: "hasSeenOnboardingStory") == nil {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboardingStory")
    }
}
// hasSeenOnboardingCoach is left at its real default (false) in both branches —
// fresh installs get it after the cards; existing installs get it on their next
// cold launch with no cards in front of it.
```

This needs no dependency on any other key's prior existence or exact semantics — it's self-contained
to this feature. A brand-new install made *after* this build ships still gets the full sequence
(`isFreshInstall == true` for them too, correctly). A reinstall after a full uninstall also gets the
full sequence (UserDefaults is wiped) — acceptable, not worth engineering around.

### 4.3 Permission-prompt ordering, restated as an invariant

1. Story cards (Tier 1) — zero side effects, never call any `LocationManager`/`CLLocationManager` API.
2. `LocationPrimingCard` (Tier 2) — the only point in this entire sequence that can trigger a system
   permission dialog, and only if `.notDetermined`, exactly as §0.2 already specifies, unchanged.
3. Coach marks (Tier 3) — copy is already location-agnostic ("Tap any block," not "near you"), so it
   reads correctly whether the user granted, denied, or dismissed Tier 2.

No code path in this spec may request location before step 2's own existing, unchanged trigger.

---

## 5. ASCII wireframes (393×852 pt reference)

### 5.1 Story card 1 of 3

```
+--------------------------------------+
| [===][   ][   ]                 Skip |  progress: seg 1 filled, 6pt gaps
|                                       |  Skip: footnote, ultraThinMaterial
|                                       |
|        +-------------+               |
|        |   green     |               |  illustration, top 45%,
|        |=============|  <- gutter    |  min height 160pt
|        |    red      |               |  ParkingColors.freeComfortably /
|        +-------------+               |  .restrictedNow
|          Mon         Tue             |
|                                       |
|  Parking here is a game you play     |  .largeTitle.weight(.bold)
|  twice a week.                       |
|                                       |
|  Street cleaning swaps sides on a    |  .title3, Color(.secondary)
|  schedule — park on the wrong one,   |
|  and you're moving the car for       |
|  no reason.                          |
|                                       |
|  +----------------------------------+ |
|  |            Continue              | |  minHeight 56, Color(.label) fill,
|  +----------------------------------+ |  Color(.systemBackground) label
+--------------------------------------+
```

Card 2: progress `[===][===][   ]`, illustration = 3 outline circles (moon / hourglass / P-sign),
headline "Tell us what you need.", body as in §1.2, button "Continue".
Card 3: progress `[===][===][===]`, illustration = tilted trapezoid with binary green/red segments,
headline "Drive, and the map does the thinking.", body as in §1.2, button **"Let's go"**.

### 5.2 Coach layer — mark 1 (over the real Addendum-3 ambient screen, nothing dimmed)

```
+--------------------------------------+
|                               ( Q )  |  rail — full brightness, live
|                               ( … )  |
|                                       |
|        live map, full color,         |  map — fully interactive
|        fully interactive             |
|                                       |
|  +--------------------------------+   |
|  | Pick what you need.            |   |  callout bubble, regularMaterial
|  | The map will only show spots   |   |  pointer arrow angles down
|  | that match.             [Got it]|  |  toward the tile row
|  +-----------------\--------------+   |
|                      \                |
| +------------------------------------+ |
| |          Start Driving             | |  dock — undimmed, live
| +----------+ +----------+ +---------+ | 
| ((moon))   | |hourglass | | P sign  | |  <- pulsing outline ring,
| OVERNIGHT  | |FEW HOURS | | FORGET  | |     traced on this row only
| +----------+ +----------+ +---------+ |
|                                  Skip |  same position on every mark
+--------------------------------------+
```

Mark 2: bubble moves to sit just above the selected Overnight tile, pointer up into the map, copy
"Green means you're covered. Red means you'll have to move it.", button "Got it".
Mark 3: bubble anchors near the nearest real curb segment (or map center fallback), pulsing ring traced
on that one polyline, copy "Tap any block to see why.", button "Done".

### 5.3 More sheet — new rows (delta only; full sheet per `goal-first-ambient-design.md` A3.4/A3.7)

```
+--------------------------------------+
|              ----- (drag)            |
|  More                          Done  |
|  +--------------------------------+  |
|  | [flag]   Report                 | |  64pt rows, unchanged
|  | [spark]  How WePark works       | |  NEW — sparkles, blue square
|  |          Replay the quick tour  | |
|  | [ ? ]    What the colors mean   | |  existing, renumbered
|  | [book]   Parking 101            | |  NEW — book.closed.fill
|  |          The full guide to NYC  | |
|  |          parking rules          | |
|  | [pal]    Show all parking rules | |  existing, renumbered, toggle
|  | [car]    Find my car            | |  existing, only when parked
|  +--------------------------------+  |
+--------------------------------------+
```

---

## 6. Implementation notes for @ios-engineer

**New files:**
- `Views/OnboardingStoryView.swift` — the 3-card `TabView(.page)` cover, custom progress bar, Skip,
  Continue/"Let's go". Presented via `.fullScreenCover`, not `.sheet` (no drag handle — a handle would
  invite accidental early dismissal before the Skip/Continue semantics are read, same reasoning
  `curb-pin-placement-design.md` §3 gives for not making its own card draggable).
- `Views/OnboardingCoachOverlay.swift` — the 3-bubble sequence. Use `anchorPreference`/
  `overlayPreferenceValue` keyed to the real `goalTileRow`, the selected tile, and the nearest-curb
  polyline — **do not hand-compute screen offsets against sibling views.** This is the exact bug class
  `goal-first-ambient-design.md` Addendum 2 (A2.1) root-caused and fixed once already (a hardcoded
  clearance constant chasing a sibling's height); anchor preferences make the bubbles track the real
  layout for free, including at different Dynamic Type sizes or if the dock's height ever changes again.
- New `AppConstants.onboardingStoryEnabled: Bool` — **its own flag, dark-ships `false`, decoupled from
  `driveModeDefaultEnabled`** so copy iterations don't require re-flipping the big flag. Functionally
  AND'd with it at every call site (`AppConstants.driveModeDefaultEnabled && AppConstants.
  onboardingStoryEnabled && ...`) since onboarding that explains a screen the user can't reach is
  meaningless — but kept as a second boolean specifically so QA/Kevin can smoke-test copy changes
  without touching the main flag's own flip timeline.

**Modified files:**
- `goal-first-ambient-design.md` Addendum 3's More sheet (§A3.4 table) — insert the two new rows per
  §3.1 above, renumber the rest. No layout change to the sheet's row anatomy (64pt, icon-square, title +
  subtitle — unchanged).
- Root view (wherever `ContentView`'s `.fullScreenCover`/onboarding gates would live) — add the
  `hasLaunchedWeParkBefore` check (§4.2) ahead of evaluating `shouldShowOnboardingStory`.

**Reused, unchanged:**
- `LocationPrimingCard` — zero code changes, kept at its existing trigger point (§1.4).
- `ParkingGuideView` / Parking 101 — zero content changes, only a new More entry point (§3.3).
- `CurbSnapIndex.nearbyBlockfaces` — reused for coach mark 3's anchor target (§2.2), same index the
  VoiceOver curb list already uses per the curb-pin placement work.
- `ParkingColors` constants — reused for the story illustrations (§1.3), no new color values.

**Swift compile-failure classes reminder (project standing list):** qualify `WePark.Category` in any
new test target that touches these views, per this project's own named gotcha list.

**Acceptance checks for @qa-verifier:**
1. Fresh install: cold launch shows exactly 3 story cards → (if `.notDetermined`) the existing
   `LocationPrimingCard` → 3 coach marks, in that order, with zero permission dialogs before Tier 2.
2. Skip on any story card jumps straight to Tier 2/3 (does not skip the coach layer).
3. Tapping a real goal tile during coach mark 1 dismisses that mark and advances; panning the map during
   any mark clears all remaining marks.
4. Upgrading install (simulate by pre-seeding `hasLaunchedWeParkBefore = true` and flipping
   `driveModeDefaultEnabled`): next cold launch shows the coach marks with **zero story cards**.
5. "How WePark works" from More replays cards + coach without touching either one-shot flag, and does
   not re-show `LocationPrimingCard`.
6. "Parking 101" row opens the unchanged `ParkingGuideView`.
7. Coach layer never mounts while `driveModeActive`/`blockSelectModeActive`/`spotPlacementActive`.
8. AX3/AX5 Dynamic Type: story card text scrolls above a fixed Continue button, illustration holds its
   160pt floor; coach bubbles wrap to 4 lines without clipping or running off-screen.
9. No green, orange, blue (selection aside), or red anywhere in new chrome except the illustrations'
   literal curb-color use and the live goal-tile/map colors the coach marks point at.

---

## 💡 Out of scope (future, captured not requested)

- A 4th story card or a coach mark specifically for the curb-pin placement flow
  (`curb-pin-placement-design.md`) — that mode already ships its own first-3-entries hint pill
  (§A.4/§3.4 of that doc); folding it into this sequence would make Tier 3 longer than the "under 15
  seconds" bar this spec holds itself to. Revisit only if field testing shows placement mode is
  genuinely undiscovered.
- Remembering whether a user finished vs. skipped the story deck, for any analytics/resurfacing
  purpose — not requested, not built.
- A fourth coach mark for "Start Driving" itself — deliberately left out; its own visual weight (bordered,
  not filled, demoted above the tiles per `goal-first-ambient-design.md` §2.1) is already designed to
  read as "the secondary action" without a lesson, and Kevin's own 5-second walkthrough (§5 of that doc)
  confirms it does.

---

## Summary for the orchestrator

Three full-screen story cards (`OnboardingStoryView`, new) tell the honest arc — the twice-a-week
side-swap problem, "tell us what you need," "the map does the thinking" — with code-drawn curb-line
illustrations in the real palette, a 3-segment progress bar, Continue/Skip, and a light selection haptic
per transition. `LocationPrimingCard` stays exactly where it is today, kept deliberately separate from
the cards (different risk class — it's the only thing in this whole sequence that can trigger a system
dialog). After the cards, 3 non-blocking coach bubbles (`OnboardingCoachOverlay`, new, anchor-preference
positioned, never dims or blocks the map) teach the real goal tiles, the green/red meaning, and
tap-a-block. Replay lives as a new "How WePark works" row in More, alongside a new "Parking 101" row
that finally gives the existing deep guide a home outside Search. State: three new one-shot
`UserDefaults` keys plus a `hasLaunchedWeParkBefore` sentinel that lets existing installs skip straight
to the coach layer (once) on the build that flips `driveModeDefaultEnabled`, never seeing the story
cards meant for someone who's never used WePark at all. New flag `onboardingStoryEnabled`, decoupled
from the big flag so copy can iterate independently.

File: `/root/repos/parkmap/docs/design/first-run-onboarding-design.md`
