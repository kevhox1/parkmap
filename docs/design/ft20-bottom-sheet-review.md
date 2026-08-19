# FT-20 bottom-sheet navigation — design review (pre-code)

**Reviewer:** Designer (read-only on source).
**Trigger:** Tech Lead, `docs/ft20-bottom-sheet-navigation-spec.md`, same "catch it before TestFlight"
gate FT-18 got.
**Scope:** §3–§6 of the spec — product design (search/place/Go), the three-detent architecture, the
FT-15 block-select boundary, the Drive Mode boundary. Kevin's ten settled rulings (six FT-20 design
decisions + four OQ rulings, both dated 2026-08-19) are **not** re-litigated anywhere below — every
finding here is about how the settled direction will actually feel in the hand, not whether it's the
right direction.
**Method:** Static read of the spec doc plus the actual code it references —
`ios/WePark/WePark/ContentView.swift` (search field padding, `recenterButtonStack`, `driveEntryButton`,
`bottomSafeAreaContent`, `blockSelectBar`, `handleLongPress`/`enterBlockSelectMode`), every existing
`.presentationDetents(...)` call site in the codebase (13, all `.medium` or `.medium, .large` — see
Finding B1), and `Views/DriveModeDestinationView.swift` (the view this spec relocates). **No Xcode, no
simulator, no screenshots available on this machine** — this is a spec-and-code read, not a visual
pass. Every finding below is inferred from source and from documented Apple HIG/Apple Maps behavior,
not from anything rendered.

---

## Summary

The product design is sound and the spec is unusually disciplined about naming its own tradeoffs — the
FT-15 hide-not-peek call, the Drive Mode boundary, and the "place" state's Go-button primacy are all
correctly reasoned and I'd ship them as written. The real risk in this spec is not the product thinking,
it's an **internal contradiction in the architecture section**: §0 rules out `.medium` by name ("use a
CUSTOM detent, not `.medium`"), and then §4.1's own recommended code sample uses `.medium` verbatim as
the middle detent, in a form nearly identical to all 13 other `.presentationDetents` call sites already
in `ContentView.swift`. An engineer moving fast on a first-of-its-kind component has every reason to
copy that block literally. If that happens, Kevin gets exactly the "sheet eats half the map" outcome he
explicitly rejected, discoverable only after a full Stream A–C build, on the single most contended file
in the project. That contradiction, plus the fact that neither detent height accounts for Dynamic Type,
are the two things I'd fix in the spec text before Stream A starts. Everything else below is
should-fix or polish.

---

## Findings

### 🔴 Blocking (fix in the spec before Stream A starts)

**B1 — §4.1's recommended code sample contradicts §0/OQ-3's own ruling on the medium detent.**
- **Where:** `docs/ft20-bottom-sheet-navigation-spec.md` §4.1 (the `.presentationDetents([.height(96),
  .medium, .large], ...)` code block) vs. §0's OQ-3 ruling text immediately above it: *"use a CUSTOM
  detent, not `.medium`... Size it to exactly the search bar plus three action rows and no more."*
- **What:** The ruling explicitly rejects system `.medium` (Kevin's own words: *"if we do medium then
  can it be pushed down to give more room of the map?"*) because it's ~40% of screen height —
  substantially taller than "search field + 3 short rows" needs. §4.2's table then also just writes
  "Medium ~40% screen," which is the system default fraction, not a value derived from measuring the
  actual content. So the spec states the ruling correctly in prose, then ships the wrong thing in the
  one code block an engineer will actually copy.
- **Why it matters:** This isn't a hypothetical slip. I checked every existing `.presentationDetents`
  call site in `ContentView.swift` (13 of them — `BlockDetailView`, `PinDetailSheet`,
  `ParkedCarDetailView`, `SettingsView`, `ParkUntilSheet`, etc.) — **every single one** uses literal
  `.medium` or `[.medium, .large]`. That's the established, muscle-memory pattern in this exact file.
  `@ios-engineer` copying §4.1's block verbatim (which is written to look like drop-in boring
  technology, per the spec's own framing) is the *likely* outcome, not an edge case. If it ships, the
  bug is invisible to every automated check in this project's QA process (unit tests, architecture
  diffs) — it only surfaces at Kevin's on-device smoke, which per this file's own history (F1–F4, the
  #31 saga, W8.5c-polish's revert) means a full extra round-trip through the most contended file in the
  codebase, eating directly into the 4.5–6.5 session estimate (§11 already flags this file's
  follow-up-round track record; this would be exactly that class of follow-up, avoidable for free right
  now).
- **Suggested fix:** Strike `.medium` from §4.1's code sample. Replace the middle case with a detent
  whose value is *computed from the actual rendered content*, not a magic number — see B2 for the
  mechanism (they're the same underlying gap: "custom" was specified as an outcome, not as a technique).
  Add one sentence to §4.1 making the contradiction impossible to miss on a skim: *"NOTE: this is NOT
  system `.medium` — do not copy that token from any of the other 13 `.presentationDetents` call sites
  in this file."*

**B2 — Neither the 96pt peek nor the "content-fit" medium detent accounts for Dynamic Type; nothing in
§4.2/§7 specifies how the height is computed at accessibility text sizes.**
- **Where:** §4.2's detent table (`Peek | ~96pt`, `Medium | ~40% screen`) and §7 AC-1–AC-6 (sheet
  mechanics — none mention text size).
- **What:** 96pt is a plausible fit for "grabber + one-line search field" **at the default Dynamic Type
  size** — I traced the existing `searchField` view (`DriveModeDestinationView.swift:218–242`:
  `.padding(10)` + a `TextField` line + `.padding(.vertical, 12)`) and the arithmetic works out to
  roughly 90–100pt today. But that number was never computed against text size — it's a fixed point
  value, and SwiftUI's `.height(96)` detent case does not grow with the user's font-size setting. At
  larger accessibility sizes (AX1–AX5), a single-line `TextField` at `.body`/`.headline` can need
  40–50pt of line height on its own before padding — comfortably more than the entire 96pt peek budget.
  The same problem recurs one level up: OQ-3's own promise ("search bar plus three action rows and no
  more") is a content-fit target, and content-fit targets have to be *measured*, not asserted as a
  static height, or the "and no more" half of the promise silently breaks at large text sizes (either
  the three rows get clipped/require an internal scroll the spec never describes, or the sheet balloons
  well past what "no more" was supposed to guarantee).
- **Why it matters:** Dynamic Type support is a stated bias for this review and a real HIG requirement —
  Apple's guidance is that fixed-height containers holding user-facing text should not be assumed to fit
  at every content-size category; text should be allowed to reflow rather than clip
  ([developer.apple.com/design/human-interface-guidelines/typography](https://developer.apple.com/design/human-interface-guidelines/typography),
  [developer.apple.com/design/human-interface-guidelines/sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
  — noting for the record that Apple's site did not return renderable text to this environment's fetch
  tool, so I'm citing the URLs per your instructions rather than quoting text I didn't actually see).
  This is exactly the class of bug that's invisible in a simulator smoke at default text size (which is
  how every prior FT-18/FT-15 smoke in this project's history has been run) and only shows up if Kevin
  happens to test at a larger system font size — low probability of being caught before TestFlight,
  high annoyance if a real accessibility-size user hits it.
- **Suggested fix:** Specify that both the peek and medium detent heights are computed at runtime from
  actual content — either `PresentationDetent.height(_:)` fed by a measured value (a `GeometryReader` +
  `PreferenceKey` reading the search field/list content's real height, re-measured on
  `dynamicTypeSize` change) or a `CustomPresentationDetent`-conforming type (the iOS 16.4+ API built for
  exactly this — it receives `context.maxDetentValue` and can return an intrinsic-content height rather
  than a hardcoded fraction). Add one AC to §7's "Sheet mechanics" group: *"Peek and medium detent
  heights reflect actual content height at the device's current Dynamic Type setting — verified at
  default and at least one accessibility size (e.g., AX3) before merge, not just default size."*

---

### 🟡 Significant

**S1 — The medium-detent's 3-item list has no visual spec at all.**
- **Where:** §3–§4.2 (the ASCII wireframe in §3.2 only shows the "place" state; the medium-detent list
  is described only as "Settings / Cruise / Parking 101 — short labels, one control language," §2 and
  §4.2).
- **What:** Row style, icon-vs-no-icon, spacing, and background are all unspecified. This matters more
  than it would for a small tweak because this is explicitly a first-of-its-kind component (§11.1) with
  no in-app precedent to fall back on by default — an engineer has to invent something, and without
  guidance the natural options pull in different directions: FT-18's capsule/pill "Bottom Dock" language
  (floating chrome over the map) doesn't actually fit here, because these rows live *inside* sheet
  content, not floating over live map — the correct native idiom is the same one already used two rows
  down in this exact sheet, once search relocates in (`recentDestinationsList`/`suggestionsList` already
  use `List` + `Section`, `.listStyle(.insetGrouped)`, `DriveModeDestinationView.swift:269–362`).
- **Why it matters:** Left unspecified, the risk isn't a HIG violation exactly — it's inconsistency
  between two pieces of chrome that live in the *same sheet, one scroll away from each other*
  (suggestions/recents list above, the 3-item list below), each independently invented without
  reference to the other.
- **Suggested fix:** Spec the 3-item list explicitly as `List` rows (not custom capsules): SF Symbol
  leading icon (`gearshape` / a cruise-appropriate glyph, reusing `car.front.waves.right.fill` from the
  soon-to-be-deleted `driveEntryButton`, `ContentView.swift:1637` / `questionmark.circle`) + `.headline`
  or `.body` label, matching the `recentDestinationsList` row anatomy verbatim. Zero new pattern, and it
  answers the task brief's "extend FT-18's control language, not compete with it" instruction correctly
  — the extension here is "use the sheet's own existing list idiom," not "reuse floating-chrome capsule
  buttons where they don't belong."

**S2 — "Parking near here" has no color treatment, breaking from the app's own established
red/amber/green convention.**
- **Where:** §3.2's wireframe (`🅿️ Parking near here: mostly free`) and §7 AC-10.
- **What:** The spec buckets the result into mostly-free / mixed / mostly-restricted (good — reuses the
  existing `ParkingRulesEngine`/`CurrentState` classification) but never says the bucketed word itself
  should carry the matching semantic color. As written, the natural default rendering is plain
  `.secondary` gray text, same as the distance line above it.
- **Why it matters:** This is the one cross-cutting bias in this review with the most established
  precedent in the app — green/amber/red already means something specific everywhere else (the
  polylines, the ASP banner, `ParkingColors.swift`). A glanceable one-line summary that reports the same
  three-way classification in plain gray text is a missed opportunity for the exact "1–2 second glance
  at a stoplight" legibility this app is built around, and it's inconsistent with every other place this
  classification appears on screen.
- **Suggested fix:** Render the bucketed word ("mostly free" / "mixed" / "mostly restricted") in the
  matching `ParkingColors` semantic color (reuse the existing green/amber/red constants, not new ones),
  the same way chip text does in `DriveModeBottomCard`. Small, one-line spec addition to §3.2 and a new
  clause on AC-10.

**S3 — No explicit AC for the reverse of AC-28 (Drive-Mode-exit / sheet-reappear race).**
- **Where:** §6 ("Exiting Drive Mode... the sheet reappears at peek") and §7 AC-28/AC-29.
- **What:** AC-28 explicitly requires "no frame where both [the sheet] and FT-18's Bottom Dock are
  simultaneously visible" on **entry**. AC-29 states the sheet "reappears at peek" on exit but doesn't
  carry the same zero-overlap requirement forward — it's implied, not stated.
- **Why it matters:** This file's specific, well-documented failure mode across FT-17a/FT-18/W8.5c-polish
  is exactly transition-timing bugs, not static layout bugs (F2's gear/End-pill coordinate collision, the
  #31 saga's camera-mutation-during-view-update regression). A system `.sheet()` presenting back in
  (`.browseNav`) and a `.safeAreaInset`-driven `VStack` row (`DriveModeBottomCard` and friends)
  animating out are two different presentation mechanisms with no inherent coordination — there's a
  real, specific way this could go wrong (a frame or two where the browse sheet's peek search bar and
  the tail end of the Bottom Dock's dismiss animation overlap) and the spec's own precedent (AC-28) shows
  the author already knows to guard for this on entry; the mirror case just got dropped.
- **Suggested fix:** Add an explicit AC-29a: *"The instant `driveModeActive` flips false, no frame shows
  both the outgoing Bottom Dock and the reappearing browse sheet simultaneously — same zero-overlap bar
  as AC-28, mirrored for exit."* Same for the FT-15 block-select boundary — see S4.

**S4 — Same timing-overlap risk exists at the FT-15 boundary, and isn't named anywhere in §5.**
- **Where:** §5.1 ("the sheet is force-set away from `.browseNav`... the sheet just gets out of the
  way") and AC-23/AC-25.
- **What:** Entering block-select mode swaps two different presentation mechanisms — the system `.sheet`
  (browse nav, dismissing) and `blockSelectBar` (a `VStack` row inside `bottomSafeAreaContent`,
  appearing) — at nearly the same moment `blockSelectModeActive` flips true. I traced the actual entry
  path in code: it's triggered from a `.confirmationDialog` action
  (`ContentView.swift:2536–2546`'s `enterBlockSelectMode()`, reached via the long-press resting-menu's
  third option), which is itself a system-presented sheet dismissing at the same time. That's three
  overlapping presentation/dismissal animations in a tight window (confirmationDialog dismiss, browse
  sheet dismiss, blockSelectBar appear) for a feature whose entire point is that the map underneath must
  be immediately, reliably tappable.
- **Why it matters:** Same class of risk as S3, but higher-stakes here because the very next user action
  after this transition is a precision tap sequence on the map (§5.1's own framing: "a feature whose
  entire job is precise, sequential multi-tap accuracy"). If the map isn't fully settled — sheet chrome
  visually gone, no residual tap-intercepting overlay — before the user's first tap lands, the first
  blockface selection could silently miss.
- **Suggested fix:** Add one AC under the FT-15 boundary group (§7): confirm via inspection/smoke that
  by the time the confirmationDialog's own dismiss animation completes, the browse sheet is already
  fully gone (not mid-animation) — i.e., sequence `blockSelectModeActive = true` so it doesn't race the
  dialog's own dismissal, or accept a documented ~0.3s "settling" window and confirm the map doesn't
  register taps during it. Low cost to spec now, real cost to debug later if skipped (this is precisely
  the kind of thing simulator smoke catches only if someone taps fast immediately after opening
  block-select, which QA's usual pass may not do).

**S5 — No AC for how a user backs out of an in-progress, no-selection search at the large detent.**
- **Where:** §3.3 ("Auto-expand on search focus") and §4.3's disposition table (`NavigationStack` +
  `Cancel` toolbar button — **"Removed. Not a modal anymore — dismissing 'back to search' is just
  collapsing the sheet or clearing the query, no explicit Cancel needed"**).
- **What:** Today's `DriveModeDestinationView` guarantees keyboard dismissal via its `NavigationStack`
  toolbar `Cancel` button. The new sheet removes that button on the reasoning that dragging down or
  clearing the query replaces it — true in spirit (this does match real Apple Maps, which also has no
  visible Cancel button in its expanded search state), but I checked and **none of the 13 existing
  `.presentationDetents` sheets in this codebase set `.scrollDismissesKeyboard`** on their inner lists,
  including the `recentDestinationsList`/`suggestionsList` this spec relocates verbatim. Dragging the
  sheet's grabber down while the keyboard is up should still work (the grabber sits above the keyboard
  regardless), but the more common real gesture — scrolling the suggestions list down, which is how
  people dismiss keyboards in `List`-based search UIs system-wide — currently has no guarantee of
  working here.
- **Why it matters:** Small but real — without it, a user who starts typing, changes their mind, and
  tries to scroll the list away (the standard iOS gesture) gets a stuck keyboard instead of a graceful
  collapse.
- **Suggested fix:** Add `.scrollDismissesKeyboard(.interactively)` to `suggestionsList`/
  `recentDestinationsList` when they move into the new sheet (§4.3's "kept verbatim" table should get one
  addition rather than being fully verbatim), and add one AC confirming it.

**S6 — Sunlight legibility of the sheet chrome + top-right rail is untested, and dark mode's flip was
explicitly not a legibility fix.**
- **Where:** §8 (dark-mode dependency note) and the top-right `recenterButtonStack`
  (`ContentView.swift:1553–1612`, `.regularMaterial` background, unchanged by this spec).
- **What:** This is a carry-over risk, not something FT-20 introduces — the same `.regularMaterial` +
  `Color.accentColor` icon-button anatomy the top-right rail already uses today is what this spec
  continues using for Locate/Find-my-car/Park Until. I can't evaluate contrast without a device or
  screenshot (flagging that plainly rather than implying I saw anything render). What I can say from the
  written record: TF2-18 already logged a real sunlight-legibility problem once, and per this task's own
  briefing, the recent always-dark default (#83) was explicitly **not** shipped as a legibility fix —
  it's "for cleanliness." That means the sunlight question is still genuinely open for whatever chrome
  sits over the map, including the (unchanged) top-right rail and the (new) sheet's `.regularMaterial`/
  system-background surface.
- **Why it matters:** Kevin drives with the phone on a windshield mount in sunlight — this is the one
  real-world condition this whole app is designed around, and it's the one condition none of this
  project's simulator smokes can test.
- **Suggested fix:** Not a spec change — a QA/smoke-checklist addition. When Kevin does his on-device
  pass for this feature, explicitly ask him to check the top-right rail and the sheet's peek/medium
  chrome in direct sun, not just indoors/simulator, given the TF2-18 precedent. Cheap to ask for, easy to
  forget since nothing in the FT-20 spec calls it out.

---

### 🟢 Polish

**P1 — "Cruise" reads identically to "Settings"/"Parking 101" in the medium list, but it's a different
kind of row (it starts a live session; the other two are navigational pushes).**
Once S1's row style is settled, give Cruise's leading icon an accent tint (matching the "Go" button's
prominence language) while Settings/Parking 101 stay neutral/secondary-tinted — a small, cheap way to
telegraph "this one does something, the other two just open something" at a glance, consistent with how
`ParkUntilPill`'s clock icon already flips to accent-green when its filter is live.

**P2 — Confirm final SF Symbol choices before Stream C; the spec's own ASCII wireframe uses literal
emoji glyphs (🔍 📍 🅿️) as shorthand.**
Given this is a brand-new view built from a wireframe (not a straight code relocation like the rest of
§4.3), it's worth one explicit sentence in §3.2 confirming these are ASCII-art placeholders for SF
Symbols (`magnifyingglass`, `mappin.circle.fill`, a parking glyph such as `p.circle.fill` or
`parkingsign.circle.fill`) — this codebase's track record on avoiding emoji-as-icon is clean (FT-18's
review confirmed "no webview tells anywhere in this surface"), so this is a belt-and-suspenders note,
not a real risk.

**P3 — Two greens on screen at once, once Park Until and the "place" state's parking summary (S2) can
coexist.**
Once S2 ships, "Park Until" active (green clock icon, top-right) and "Parking near here: mostly free"
(green text, inside the place state) can both be visible simultaneously if a user sets a time filter and
then searches a destination. Not a conflict today (nothing green-codes the place state yet), but worth a
one-time glance-check once both exist: confirm the two greens read as "two different, unrelated
green-meaning-free facts" rather than looking like one linked control.

---

### 💡 Out of scope (future, already correctly deferred)

- **Richer parking-context in the place state** (highlighting specific nearby blocks, Smart-Move-style
  ranking) — §10 already names this as the ceiling for this slice and defers it. Agreed; the cheap
  one-line bucketed summary (once S2's color fix lands) is the right scope for now.
- **A real-device VoiceOver + motion a11y pass on the drag interaction** — §10 already defers this
  beyond the AC-34/35 minimum bar. Agreed — system `.sheet` gives VoiceOver's adjustable grabber action
  for free under Option A, which is most of the value; a dedicated pass is reasonable as a follow-up.
- **A confirm-before-committing preview of the parking summary before Go**, once the richer §10 version
  ships — noting the idea here so it isn't lost, not proposing it now.

---

## What's working

- **The "hide, don't peek" call for FT-15 block-select (§5.1) is the right call, correctly argued.** The
  spec's own reasoning — that even a 96pt peek sits directly over the exact screen region a precision
  multi-tap task needs unobstructed — is sound, and it correctly reuses an already-proven exclusion
  precedent (`ParkingGuidePromptBanner`'s "deliberate focused task" framing) rather than inventing a new
  rule for this one case.
- **The entry AND exit affordances for block-select are both real, not just "the UI vanishes."** Entry
  is an explicit user-initiated action from a native `.confirmationDialog` ("Report closure..."), not a
  silent state flip — the user has just told the app what they're about to do. Exit has an explicit
  `Cancel` button inside `blockSelectBar` itself. I looked for a "mysterious vanish with no way back"
  problem specifically (per the task brief) and didn't find one — the only real gap is the *timing* of
  the transition (S4), not the *legibility* of it.
- **The Drive Mode boundary's asymmetric detent choice is a good, considered decision, not an
  oversight.** Peek-on-exit (§6) rather than "wherever it was left" is the right call for Drive Mode
  (a completed session, stale search state), while block-select's "restore prior detent" (§5.1) is the
  right call for a much shorter interruption. The spec treats these as two different kinds of
  interruption rather than reusing one rule for both — that distinction is easy to miss and the spec
  got it right.
- **The "Go" button's primacy is inherited from an already-correct pattern, not invented fresh.**
  `startDriveSection`'s existing `.buttonStyle(.borderedProminent)` + `.frame(maxWidth: .infinity)` +
  `.font(.headline)` treatment (`DriveModeDestinationView.swift:387–399`) is a standard, unambiguous
  system primary-button treatment already. Renaming "Start Drive" → "Go" (shorter, and correctly
  justified — there's no cruise option on this screen to disambiguate from) is the right fix for the
  FT-20 "button text too long" complaint, and it costs nothing extra since the button anatomy carries
  over verbatim.
- **The top-right rail is a net decluttering, not a new risk, despite going from "two icons" to "three
  icons" in this review's framing.** I checked the actual code: today's shipped `recenterButtonStack`
  already renders **four** stacked 44×44 buttons (Find me / Find my car / Park Until / the combined
  Drive-entry Menu, `ContentView.swift:1553–1612`). This spec *removes* the fourth (absorbed into the
  sheet) and keeps the other three verbatim, same anatomy Kevin already validated on-device for FT-18's
  analogous chrome. Three is not "one too many" here — it's fewer than what's already shipped and
  already approved.
- **§4.3's "what's kept / what's lost" accounting is genuinely thorough** — every sub-view of
  `DriveModeDestinationView` (completer, recents, error banner, auth gate, out-of-coverage toast) has an
  explicit disposition, which is exactly the discipline a real refactor (not a rebuild) needs and is why
  most of this review is about the *new* surface (the medium-detent list, the place-state color
  treatment) rather than the relocated one.
- **No emoji-as-icon, no hand-rolled button chrome anywhere in the actual code this spec touches** — the
  only emoji in the entire spec are in its own ASCII wireframes (P2), which is a documentation
  convention, not a code smell.

---

## Risk to the 4.5–6.5 session estimate

**B1 is the one genuine risk to the estimate**, and it's asymmetric: fixing it in the spec now costs
nothing (a sentence + a corrected code sample). Not fixing it costs a full extra round-trip through
Stream A + a re-test of Stream C's mount, discovered only at Kevin's on-device smoke — exactly the kind
of late, expensive catch this design-review gate exists to prevent. B2 (Dynamic Type) is lower-probability
(only surfaces if Kevin or a real user is running a larger text size) but comparably expensive if it does
surface, for the same reason: it's invisible to unit tests and to a default-size simulator smoke. S3–S5
(timing/overlap ACs) are cheap insurance against this file's documented failure mode and are worth adding
to the AC list now rather than after a QA pass finds them the hard way — but none of them are estimate-
moving on their own the way B1 is.

---

## Count

**2 must-fix (blocking) findings.** The single change I'd most want made before Stream A starts: **fix
§4.1's code sample so the middle detent is a genuinely content-measured custom height, not `.medium`**
(B1) — it's the one place the spec's own stated ruling and its own recommended implementation
contradict each other, it's the most copy-paste-likely code in the whole doc, and getting it wrong is
invisible until Kevin's on-device smoke on the most contended file in the project.
