# FT-12 — Beginner's Manual: "Free Parking in NYC 101"

**Status:** Spec drafted 2026-07-09. Awaiting Kevin's sign-off on Open Decisions below before `@ios-engineer` starts.
**Owner:** `@ios-engineer` (build), `@designer` (review), Tech Lead (spec).
**Depends on:** PR #45 (Help & FAQ) merged — `FAQHelpView.swift`, `docs/in-app-faq-content.md`, `SettingsView.swift` Help section. W4.5 palette (`docs/design/ios-mvp-palette.md`) for color semantics. W8.5c `BackgroundNoteGate` (`Services/Constants.swift:92-127`) as the one-shot-gate precedent.
**Blocks:** Nothing. Independent of all in-flight TF2 streams (TF2-16 heading, TF2-17 chip copy, TF2-18 Drive Mode design review) — zero file overlap, safe to run concurrently.
**Source request:** `docs/field-testing-log.md` FT-12 (TF2 Round 3, 2026-07-09).

---

## 0. TL;DR

New user drops into WePark and doesn't know NYC street parking is beatable. FT-12 asks for an
in-app "beginner's manual": the pitch (it's doable, here's the money you save), a sign-reading
school with visuals, how WePark's map colors map to real signs, and rookie mistakes. This spec
recommends: **a new dedicated `ParkingGuideView` screen** (not an extension of the flat FAQ list),
reached from Settings and cross-linked from `FAQHelpView`, with **SwiftUI-rendered vector sign
replicas** (no bundled images), a **non-blocking one-shot first-launch banner CTA**, and
**dollar figures stored as named constants with a source citation** so they're a one-line update
later rather than buried string literals. iOS-only, no backend, no PWA. Estimated **2 engineering
sessions + 1 fix-pass** (see §8).

---

## 1. Open Decisions (need Kevin's confirmation before code starts)

Each item has a recommendation. Silence = ship the recommendation.

**OQ-1 — Surface: new screen vs. extend `FAQHelpView`?**
**Recommendation: new dedicated screen, `Views/ParkingGuide/ParkingGuideView.swift`.**
`FAQHelpView` is a flat Q&A list (3 sections, all text, ~280 lines). FT-12 asks for a money-math
pitch, a multi-sign illustrated gallery, a color legend, and a mistakes list — that's a different
content shape (narrative + visual gallery, not Q&A) and would roughly double `FAQHelpView`'s size
if bolted on. A dedicated screen keeps each surface doing one job: FAQ = quick reference, Parking
101 = the onboarding narrative. They cross-link each other (§3).

**OQ-2 — First-launch prompt: yes/no, and what shape?**
**Recommendation: yes, but a non-blocking one-shot banner CTA, not a modal.**
`BackgroundNoteGate` (§7) is the existing one-shot precedent, but it's a blocking `.alert` —
justified there because it's safety info shown *mid-task* (first Drive Mode start). This is
different: it's promotional/educational content shown at cold launch, exactly when the location
and notification permission dialogs may also be competing for the user's first few seconds. A
blocking sheet/alert risks stacking on top of those system prompts. Recommendation: a small
dismissible bottom banner ("New to NYC parking? Free parking is doable — read the guide →")
rendered via `.safeAreaInset(edge: .bottom)` (same technique as the W7.5 Park-Until pill), shown
once, auto-hidden after first interaction with the map (first pan/tap) or after ~8s, with an X to
dismiss and a tap target that opens `ParkingGuideView`. The map is fully usable underneath at all
times — this is the "don't block the map" requirement from the task brief.

**OQ-3 — Sign image asset strategy: SwiftUI vector replicas vs. bundled raster images?**
**Recommendation: SwiftUI vector replicas via a reusable `SignPlateView` component. See §5.**

**OQ-4 — Money-math figures: what numbers, how prominent?**
**Recommendation: a conservative range with a source citation and an explicit "figures vary"
disclaimer**, not a single splashy hero number. See §3(a) for the exact language and sourcing.
Store as named constants (§6) so a future refresh is a one-line change — this repo already has an
annual-refresh pain point with the ASP calendar (`HANDOFF.md` "2027 ASP calendar refresh"); don't
create a second one buried in view code.

**OQ-5 — Tone: calm/plain (existing FAQ voice) or warmer/encouraging for the pitch section?**
**Recommendation: mostly the existing calm/plain FAQ voice, with the Pitch section (§3a) allowed
to be warmer and more encouraging** since its job is specifically confidence-building — still no
absolutes ("always," "guaranteed," "never get a ticket").

**OQ-6 — Should `FAQHelpView` get a cross-link to the new guide?**
**Recommendation: yes**, a single line at the top of `FAQHelpView` Section 1: "New here? Read the
full Parking 101 guide →" linking to `ParkingGuideView`. Cheap, two-way discoverability.

**OQ-7 — Should sign-plate replicas stay light/white even in Dark Mode?**
**Recommendation: yes, deliberately.** Real NYC signs are white/red/black regardless of the time
of day; both Apple Maps and Google Maps render street-sign imagery in its real colors even in dark
mode. Auto-adapting the plate background to `.systemBackground` would make it look like an app UI
card, not a sign — undermining the "here's exactly what you'll see on the pole" pedagogy. Only the
screen chrome around the plates (background, headers, body text) adapts normally.

---

## 2. Problem & User Story

A new WePark user — someone who just moved to NYC or just bought a car — opens the app and sees a
colored map, but doesn't know *why* free parking is realistic, doesn't know what the signs on the
pole outside their building actually say, and doesn't know how to translate a sign into a WePark
map color. The existing Help & FAQ (PR #45) answers "what is ASP" in one paragraph but has no
sign visuals and no savings framing — it assumes the reader already believes street parking is
worth the effort.

> I just got a car in NYC. Everyone tells me street parking is a nightmare and I should just pay
> for a garage. I open WePark, see a small banner ("New to NYC parking? Read the guide →"), tap
> it. In two minutes I learn: (1) garages run $400-1,000+/month depending on neighborhood — that's
> real money; (2) NYC's alternate-side rule is just "move your car twice a week for street
> cleaning," and it's suspended ~40 days a year; (3) here's what the four sign types actually look
> like and what they mean; (4) here's how WePark's map colors map to those signs. I close the
> guide feeling like this is learnable, not scary.

**Why now:** Kevin's direct request (2026-07-09, FT-12), logged alongside the TF2 Round 3
drive-test findings. Distinct from those findings — this is new-user education, not a bug fix.

---

## 3. Content Outline

Source-of-truth convention: mirror the `docs/in-app-faq-content.md` precedent. This spec defines
the section list and summaries below; **`@ios-engineer` drafts the full final copy into a new
companion doc `docs/parking-101-content.md`** (same pattern as the FAQ content doc) as part of the
PR, and `ParkingGuideView` renders it faithfully. Tech Lead reviews the content doc for accuracy
before/alongside the design review pass.

Screen title: **Parking 101**. Subtitle: *Free parking in NYC is doable. Here's how.*

Top-of-screen quick-jump chip row (ScrollViewReader + section anchors) since this is longer than
`FAQHelpView` — lets a user skip straight to "Sign School" without scrolling past the pitch.

### (a) The Pitch — why free parking is doable, and the money math

1-2 sentence summary: Reframes street parking from "impossible" to "a routine you learn in a
week." Leads with the ASP rhythm (move your car ~twice a week around a posted window, suspended
~40 days/year per the existing FAQ content) and WePark's role (color-coded map + reminders do the
remembering for you). Then the money math: cite a **conservative range**, not a single number —
"Manhattan garages commonly run **$500–$1,000+/month**; citywide the average is closer to
**$400–$600/month** depending on neighborhood" (source: SpotAngels/SpotHero market data,
2026 — see WebSearch citation below; cite as "market data, verify locally" rather than a precise
DOT figure, since garage pricing is private-market and drifts). Contrast: free street parking
costs **$0** but requires the habit of moving your car and occasionally risks a **~$65 street-
cleaning ticket** (same figure already used in the existing FAQ, `FAQHelpView.swift:101`) if you
miss a window — WePark's reminders exist specifically to prevent that. Close with an honest range,
e.g. "that's roughly **$4,800–$12,000 a year** back in your pocket if you're willing to learn the
rhythm" — computed directly from the monthly range above (12× the low/high), not a separately
invented number.

### (b) Sign-Reading School — the common sign types, with visuals

1-2 sentence summary per sub-section, each paired with one or more `SignPlateView` replicas:

- **ASP / Street Cleaning signs.** What a real plate says, e.g. "NO PARKING 8-9:30AM TUES FRI
  STREET CLEANING" — explain the sign has NO literal broom icon (see the content-accuracy note in
  §5); a small SF Symbol `"trash"`/broom-style icon may decorate the *section header* only, never
  the sign replica itself.
- **The 3-tier restriction ladder — No Parking vs. No Standing vs. No Stopping.** A comparison
  table/card explaining what's actually allowed under each: No Parking = you can stop briefly to
  load/unload with the driver present; No Standing = can't remain even with the driver in the car,
  except actively picking up/dropping off passengers; No Stopping = can't stop at all, not even to
  drop someone off. This is the single most-misunderstood distinction for new drivers.
- **Metered / Muni-Meter signs.** Pay during posted hours, free outside them and on major legal
  holidays (consistent with existing FAQ copy, `FAQHelpView.swift:109`).
- **Hydrant 15-foot rule.** No sign posted at all — a universal NYC rule. Explain how to eyeball
  15 feet (roughly a car length) from a hydrant on either side.
- **Arrows and side-of-street semantics.** A regulation posted with an arrow applies in the
  direction of the arrow, up to the next sign or the corner — not the whole block, and only on
  that side of the street.
- **Combined sign stacks.** Multiple plates on one pole = all rules apply simultaneously; read
  top to bottom; the most restrictive rule in effect at a given moment wins. Directly reuses the
  "Reading the signs (the final word)" framing already in the existing FAQ
  (`FAQHelpView.swift:112-113`) — don't contradict it, extend it with visuals.

### (c) How WePark's Colors Map to Signs

1-2 sentence summary: A legend tying each of the **five** `ParkingColors` states
(`docs/design/ios-mvp-palette.md` §2.1-§2.2) to a plain-English "what sign produced this color"
explanation:
- **Red** (`ParkingColors.restrictedNow`) — a restriction (No Parking/Standing/Stopping window,
  ASP window) is active right now.
- **Orange** (`ParkingColors.restrictionComingSoon`) — free right now, but the posted restriction
  starts within 6 hours (W4.5 threshold) — fine for an errand, set a reminder for anything longer.
- **Amber-yellow** (`ParkingColors.meteredActive`) — a metered sign, meter is currently active —
  pay or move.
- **Green** — free now with nothing posted in the near term.
- **Gray** (`ParkingColors.unknown`, 0.35 opacity) — WePark has no data for this block; the sign
  on the pole is the only truth here.
Must reuse the exact `ParkingColors` static constants, not new hardcoded hex/RGB literals (AC-6).

### (d) Rookie Mistakes / Gotchas

1-2 sentence summary per bullet, e.g.: ASP resumes the very next day after a suspension (the
holiday trap); check BOTH the day letters AND the time window, not just one; a lower second plate
on the same pole can change everything the top plate says; some meters have different hours than
you'd assume — always check the plate, don't guess; standing "just for a second" near a hydrant is
still a violation; a green WePark block is a snapshot — recheck if you're staying past the horizon
shown; "No Parking" still allows a quick stop to load/unload, it is not a full ban (ties back to
the (b) ladder).

---

## 4. Architecture

**Codebases touched:** iOS only. No PWA (`index.html`/`sw.js`/`manifest.json`/`tracker-config.js`)
changes. No `supabase/**` changes. No `tiles/**` changes.

**New files:**
- `ios/WePark/WePark/Views/ParkingGuide/ParkingGuideView.swift` — screen shell: `ScrollView` +
  `ScrollViewReader`, quick-jump chip row, composes the four section subviews below. Kept thin
  per the W8.5c-polish PR-1 precedent (extract subviews to stay under the Swift type-checker
  complexity limit — don't let one file grow to 800+ lines).
- `ios/WePark/WePark/Views/ParkingGuide/PitchSectionView.swift` — §3(a).
- `ios/WePark/WePark/Views/ParkingGuide/SignSchoolSectionView.swift` — §3(b), composes multiple
  `SignPlateView` instances.
- `ios/WePark/WePark/Views/ParkingGuide/ColorLegendSectionView.swift` — §3(c).
- `ios/WePark/WePark/Views/ParkingGuide/RookieMistakesSectionView.swift` — §3(d).
- `ios/WePark/WePark/Views/ParkingGuide/SignPlateView.swift` — reusable sign-replica component.
  See §5 for the interface sketch.
- `ios/WePark/WePark/Views/ParkingGuide/ParkingGuidePromptBanner.swift` — the OQ-2 one-shot
  bottom banner CTA, rendered from `ContentView`'s `.safeAreaInset(edge: .bottom)` chain (same
  slot family as the W7.5 Park-Until pill / W8.5d approaching strip — verify no stacking
  collision if a car is already parked and that pill is also showing; banner should not render
  while `ParkUntilSheet`/approaching-strip content occupies the same inset).
- `docs/parking-101-content.md` — content source-of-truth doc, mirrors
  `docs/in-app-faq-content.md`. Drafted by `@ios-engineer` per §3, reviewed by Tech Lead.

**Modified files:**
- `ios/WePark/WePark/Views/SettingsView.swift` — new "Parking 101" row in the existing Help
  section (`SettingsView.swift:74-80`), above or below "Help & FAQ" — recommend **above**, since
  it's the more welcoming/introductory surface for a first-time visitor to Settings.
- `ios/WePark/WePark/Views/FAQHelpView.swift` — one cross-link line per OQ-6, top of Section 1.
- `ios/WePark/WePark/Services/Constants.swift` — two additions:
  1. `ParkingGuidePromptGate` struct, mirroring `BackgroundNoteGate` exactly (`Constants.swift:
     92-127`) — same shape (`shouldShow()`/`markShown()`, injectable `UserDefaults` for tests),
     new key `wepark_parking101_prompt_shown`.
  2. A `MoneyMathConstants` (or similarly named) namespaced struct holding the dollar figures
     from §3(a) as named `Double`/`Int` constants with a doc-comment citing the source and the
     date pulled (2026-07), so a future refresh is a one-line diff, not a hunt through view code.
- `ios/WePark/WePark/Views/ContentView.swift` — mounts `ParkingGuidePromptBanner` conditionally
  (gate check + no existing bottom-inset content already showing), wires its tap target to open
  `ParkingGuideView` (new `ActiveSheet` case or plain `NavigationLink`/`.sheet` — engineer's
  call, consistent with the existing `ActiveSheet` enum extensibility point from W5.1).

**No new networking, no new Supabase tables/RPCs, no new tile data.** This is 100% static bundled
content — the entire feature works offline.

---

## 5. Sign Image Asset Strategy (OQ-3, recommended: SwiftUI vector replicas)

**Recommendation: build one reusable `SignPlateView`, parameterized by text lines — zero bundled
raster images.**

Rationale:
- NYC parking signs are simple, mostly-text layouts (white background, black or red bold
  condensed text, sometimes a red border) — trivial to replicate faithfully as a SwiftUI view,
  unlike e.g. a photographed storefront.
- Vector replicas stay crisp at any Dynamic Type size and any device, with zero bundle-size cost
  (photos would add real MB and need @1x/@2x/@3x variants).
- No licensing ambiguity. NYC DOT sign designs are government works, but photographing an actual
  installed sign (with a specific pole, background, lighting) is a separate asset with its own
  upkeep/accuracy burden — if the DOT updates a sign template, a photo goes stale silently; a
  text-driven replica just needs the string data updated in `docs/parking-101-content.md`.
- **Content-accuracy note (important):** the FT-12 request describes signs by casual nickname
  ("ASP (broom)") — real NYC ASP/street-cleaning signs do **not** carry a broom icon; they are
  text plates ("NO PARKING — STREET CLEANING," days, times). A broom SF Symbol may be used
  decoratively next to a *section header* (outside the plate) as a visual mnemonic, but the
  `SignPlateView` itself must only ever render text that appears on real signs — this is the
  honesty requirement from the task brief ("mirror real sign wording"). Same rule applies to any
  other sign type: no invented icons on the plate face.

**Sketch interface** (illustrative, not final Swift):

```swift
struct SignPlateView: View {
    struct Line {
        let text: String
        let weight: Font.Weight
        let color: Color   // typically .black or .red, matching the real plate
    }

    let lines: [Line]
    let borderColor: Color   // .black (most plates) or .red (No Standing/Stopping emphasis)
    let accessibilityDescription: String  // e.g. "Sign reads: No Parking, 8 to 9:30 AM, Tuesday and Friday, street cleaning"

    var body: some View {
        VStack(spacing: 2) {
            ForEach(lines.indices, id: \.self) { i in
                Text(lines[i].text)
                    .font(.system(.headline, design: .default, weight: lines[i].weight))
                    .foregroundStyle(lines[i].color)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(12)
        .background(Color.white)             // deliberately NOT .systemBackground — see OQ-7
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderColor, lineWidth: 3))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }
}
```

Each sign instance in §3(b) is then just a data literal (lines + border color + a11y string) fed
into this one component — no per-sign SwiftUI code, no image assets, no asset-catalog entries.

---

## 6. Money-Math Figures — sourcing and freshness

Per OQ-4, figures for §3(a):
- **Monthly garage range:** $400–$600/month citywide average, $500–$1,000+/month in Manhattan.
  Source: SpotAngels NYC monthly parking guide, SpotHero NYC monthly parking listings (market
  data, pulled 2026-07-09 — see citations below). This is private-market pricing, not a DOT
  figure — copy must say "commonly run" / "market rates," never "the price is."
- **Street-cleaning ticket:** ~$65. Already used in the shipped FAQ (`FAQHelpView.swift:101`) —
  reuse verbatim, don't introduce a second figure.
- **Annual savings framing:** computed as 12× the monthly range (so $4,800–$12,000/year), not a
  separately sourced number — keeps the math auditable and internally consistent.

Store all of the above as named constants in `Constants.swift` (§4) with a doc-comment citing the
source and pull date, exactly the same discipline this repo already applies to
`AppConstants.driveModeBackgroundNoteShownKey`-style constants. This avoids a second "annual
refresh" problem alongside the existing ASP-calendar one (`HANDOFF.md` "2027 ASP calendar
refresh" backlog item) — a future price update is a one-line constant change, not a grep through
view files.

---

## 7. First-Launch Gate — precedent and shape

Directly mirrors `BackgroundNoteGate` (`ios/WePark/WePark/Services/Constants.swift:92-127`):

```swift
struct ParkingGuidePromptGate {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard,
         key: String = AppConstants.parkingGuidePromptShownKey) {
        self.defaults = defaults
        self.key = key
    }

    func shouldShow() -> Bool { !defaults.bool(forKey: key) }
    func markShown() { defaults.set(true, forKey: key) }
}
```

Difference from `BackgroundNoteGate`: this gate controls a **dismissible bottom banner**, not a
blocking `.alert` (see OQ-2 rationale). `markShown()` fires on either (a) the user tapping the
banner to open `ParkingGuideView`, (b) the user tapping the X to dismiss, or (c) an ~8s auto-hide
timer — all three count as "shown," none re-prompt on next launch.

---

## 8. Work Streams

Single-codebase feature — no PWA/backend streams, so no meaningful engineering-side
parallelization within FT-12 itself. The parallelism story here is **across** features: this
stream is file-disjoint from every currently-dispatched TF2 stream (TF2-16 touches
`LocationService.swift`/`MapViewRepresentable.swift`; TF2-17 touches
`DrivingContextService.swift`/`DriveModeBottomCard.swift`; TF2-18 is a designer-only review) —
`@ios-engineer` can work FT-12 concurrently with whichever agent/session is on those, with zero
merge risk, per `.claude/TEAM.md`'s "different features run in parallel" rule.

1. **`@ios-engineer`** — build, single serialized stream, recommend 2 PRs to keep review size
   sane (matches the W7 precedent of one feature spread across a manageable diff):
   - **PR-1:** `SignPlateView` + `ParkingGuideView` shell + Pitch section + Sign School section +
     `docs/parking-101-content.md` draft.
   - **PR-2:** Color Legend section + Rookie Mistakes section + Settings entry point + FAQ
     cross-link + `ParkingGuidePromptGate` + `ParkingGuidePromptBanner` + `MoneyMathConstants` +
     accessibility pass + tests.
2. **`@designer`** — one review pass after PR-1 lands (or after both PRs, engineer's call) per
   `.claude/TEAM.md` lifecycle. New visual pattern (`SignPlateView`) plus a money-math layout
   that didn't exist before — worth the same rigor already applied to Drive Mode (TF2-18). Checks:
   sign-plate legibility/contrast against both light and dark screen chrome, color-legend fidelity
   against the W4.5 palette, banner CTA not feeling like a dark pattern (must be easy to dismiss).
3. **`@ios-engineer`** — address designer findings.
4. **`@qa-verifier`** — fresh read against Acceptance Criteria (§9) + Test Inventory (§10).
5. **`@ios-engineer`** — address QA findings (possibly multiple passes per lifecycle norm).
6. **Kevin** — smoke on-device: Settings → Parking 101 flow, first-launch banner appears once and
   doesn't block the map, Dynamic Type at a large size, Dark Mode (confirm OQ-7's "signs stay
   light" reads as intentional, not broken).

**Session estimate:** 2 core engineering sessions (PR-1, PR-2) + 1 fix-pass session after
designer/QA findings ≈ **3 `@ios-engineer` sessions total**, plus one `@designer` pass and one-to-
two `@qa-verifier` passes (not counted as engineering sessions). This is comparable in size to W7
(ASP banner + Settings, also ~1 feature spread across a few files) — not a small tweak, but not a
multi-week stream either.

---

## 9. Acceptance Criteria

- [ ] **AC-1:** A "Parking 101" row appears in `SettingsView`'s Help section, above "Help & FAQ,"
      and navigates to `ParkingGuideView`.
- [ ] **AC-2:** `ParkingGuideView` renders all four sections in order — Pitch, Sign School, Color
      Legend, Rookie Mistakes — each reachable via the quick-jump chip row.
- [ ] **AC-3:** `FAQHelpView` contains a cross-link to `ParkingGuideView` (OQ-6).
- [ ] **AC-4:** Every `SignPlateView` instance's rendered text matches real sign wording as
      documented in `docs/parking-101-content.md` — no invented icons on the plate face (§5
      content-accuracy note); each plate has a non-empty `.accessibilityLabel` that reads the same
      literal text.
- [ ] **AC-5:** All dollar figures in the Pitch section are sourced from named constants in
      `Constants.swift` (§6), not inline string/number literals duplicated across views; each
      constant has a doc-comment citing source + pull date.
- [ ] **AC-6:** The Color Legend section uses the exact `ParkingColors` static constants from
      `docs/design/ios-mvp-palette.md` §2.2 — no new hardcoded hex/RGB values — and lists all five
      states (red, orange, amber-yellow, green, gray).
- [ ] **AC-7:** The first-launch banner (if OQ-2 approved as spec'd) shows at most once per
      install, is dismissible, does not block map pan/tap/long-press at any point while visible,
      and does not appear simultaneously with the location/notification system permission dialogs
      or with another `.safeAreaInset(edge: .bottom)` occupant (Park-Until pill, approaching
      strip, End Drive pill).
- [ ] **AC-8:** Body text in `ParkingGuideView` scales with Dynamic Type; `SignPlateView` text
      scales up to at least `.accessibility1` without clipping (verify at `.accessibility3` that
      the plate degrades gracefully — wrap or scroll, not silent truncation).
- [ ] **AC-9:** In Dark Mode, screen chrome (background/nav bar/headers/body) adapts normally;
      `SignPlateView` backgrounds remain light/white by design (OQ-7) — confirmed as intentional
      in the designer review, not flagged as a bug.
- [ ] **AC-10:** No changes to `index.html`, `sw.js`, `manifest.json`, `tracker-config.js`, or any
      file under `supabase/**` or `tiles/**`.
- [ ] **AC-11:** All new logic (`ParkingGuidePromptGate`, any pure helper functions) has unit test
      coverage per §10; the full existing test suite still passes with zero regressions (record
      exact before/after counts in the PR — baseline is 500+ as of the current `main`, confirm
      exact figure at PR time since TF2 fixes are landing concurrently).
- [ ] **AC-12:** Engineer captures a simulator screenshot of `ParkingGuideView` (all sections) and
      the first-launch banner as part of the PR, per the live-UI smoke gate norm.

---

## 10. Test Inventory

Mirrors the existing precedent for static-content views (`FAQHelpViewTests.swift` — light,
targeted tests, not heavy view-hierarchy testing, since this repo has no SwiftUI snapshot-testing
library):

- `ParkingGuidePromptGateTests` (mirrors the (currently-unnamed, embedded-in-`W85cTests.swift`)
  `BackgroundNoteGate` test pattern): `shouldShow()` is `true` on a fresh `UserDefaults` suite;
  `false` after `markShown()`; uses an ephemeral suite, never pollutes `UserDefaults.standard`.
- `MoneyMathConstantsTests` (or equivalent naming): sanity bounds — garage-range low < high, both
  positive, ticket cost matches the existing FAQ's $65 figure (guards against copy drift between
  the two screens), annual figures equal 12× the monthly constants (guards the "auditable math"
  claim in §6).
- `ParkingGuideContentTests` (mirrors `FAQHelpViewTests`'s link-validity pattern, if the guide adds
  any outbound links — likely none needed since this is self-contained, but if a "verify with
  NYC.gov" link is added, test it the same way `FAQHelpViewTests` tests its three links).
- If any pure helper functions are introduced (e.g., a section→anchor-ID mapping for the
  quick-jump chips), cover them with plain unit tests — no UIKit/SwiftUI dependency required by
  design, same discipline as `BackgroundNoteGate`.
- No snapshot/visual regression tests — not an established pattern in this codebase; visual
  correctness is covered by the mandatory engineer screenshot (AC-12) + designer review + Kevin's
  on-device smoke.

---

## 11. Accessibility

- **Dynamic Type:** all body/caption text uses relative text styles (`.headline`, `.subheadline`,
  `.body`, `.caption`), no fixed point sizes — same convention already used in `FAQHelpView`. Sign
  plates cap their *layout* concerns at `.accessibility3` (verify wrap-not-clip) since a plate is
  meant to visually resemble a real sign, but the text itself never becomes unreadable.
- **VoiceOver:** every `SignPlateView` gets `.accessibilityElement(children: .combine)` +
  `.accessibilityLabel` reading the literal sign text (§5) — a VoiceOver user gets the same
  information a sighted user gets from looking at the plate, not "image, sign plate." Section
  headers use `Label` + SF Symbol exactly as `FAQHelpView` already does
  (`FAQHelpView.swift:81-84`) for consistent heading semantics. The quick-jump chip row gets
  `.accessibilityLabel`s naming the destination section ("Jump to Sign School").
- **Color Legend section (§3c) is not colorblind-remediated beyond what the existing map palette
  already does** — `docs/design/ios-mvp-palette.md` §5.1 already documents the honest finding that
  orange/amber-yellow are close in luminance for some colorblind users. This guide inherits that
  limitation; it is not FT-12's job to fix the base palette. Each legend row pairs the color swatch
  with the plain-English label (not color alone) — same technique `FAQHelpView.mapColorsBlock`
  already uses (`FAQHelpView.swift:152-163`).

---

## 12. Out of Scope Follow-Ups (noticed, explicitly punted)

- **Localization / non-English copy.** This spec assumes English-only, matching the rest of the
  app. Not addressed here.
- **Interactive "quiz yourself on this sign" mini-game.** Would meaningfully deepen retention but
  is a distinct, larger feature (state management, scoring) — not this slice.
- **Borough-specific garage pricing (Brooklyn/Queens/Bronx breakdowns).** The money-math range in
  §3(a)/§6 is citywide-ish; a neighborhood-level breakdown would need either live pricing data
  (out of scope — no backend in this feature) or a much longer maintenance table. Deferred.
  Worth revisiting once/if the address-search or paywall backlog items (`HANDOFF.md` Phase 4/5
  backlog) give the app real location context to key off of.
- **Push/local-notification nudge ("haven't read the guide yet, tap here")** beyond the one-shot
  banner. Would be a second notification-permission ask stacked on top of the existing W6
  reminder-permission flow — explicitly avoided per OQ-2's "don't stack modals at launch"
  reasoning. If Kevin wants a stronger nudge later, that's a separate, smaller follow-up spec.
- **Video or animated sign-reading walkthrough.** Raster/video assets reintroduce the bundle-size
  and licensing questions §5 explicitly avoids. Static vector + text is the right MVP shape; if
  Kevin wants motion later, treat as a distinct enhancement, not baseline FT-12 scope.
- **Analytics on guide engagement (did the user actually read it / tap through sections).** No
  analytics infrastructure exists in the iOS app today — out of scope for this feature to
  introduce one just for this measurement.

---

## Citations (money-math sourcing, pulled 2026-07-09)

- SpotAngels, "The 2026 Ultimate Guide to Cheap Monthly Parking in NYC" —
  https://www.spotangels.com/blog/the-ultimate-nyc-monthly-parking-guide/
- SpotAngels, "Manhattan Monthly Parking — Best Rates & Deals" —
  https://www.spotangels.com/nyc/manhattan-monthly-parking
- SpotHero, "New York, NY Monthly Parking" — https://spothero.com/city/monthly/nyc-parking
- Existing in-app figure ($65 street-cleaning ticket) — `docs/in-app-faq-content.md` line 18,
  `ios/WePark/WePark/Views/FAQHelpView.swift:101`.

Note for `@ios-engineer`: these are market-data aggregator figures, not an official DOT price
list — keep the in-app copy hedged ("commonly run," "market rates vary by neighborhood and
month") rather than stated as fact, and store them as named, dated constants (§6) so a future
Kevin/tech-lead refresh is trivial.
