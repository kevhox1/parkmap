# Drive Mode UI review — 2026-07-09 (TF2-18)

**Reviewer:** Designer (read-only on source).
**Trigger:** Kevin's build-13 real-device drive-test feedback — "layout is still a bit clunky and the color scheme can be improved for visibility" (`docs/field-testing-log.md` TF2-18).
**Scope:** Drive Mode surface end-to-end — bottom card + chips, End Drive/Report/Park Here row, recenter/toolbar stack, ASP banner interplay, approaching strip, arrival prompt, sign-check sheet, W4.5 palette as used in-car.
**Method:** Static code review of the actual SwiftUI/values (no device access) + computed WCAG contrast ratios from the literal `Color` values in `ParkingColors.swift` / `ios-mvp-palette.md`, checked against Apple HIG conventions (44pt touch targets, color-plus-text redundancy, glanceable-at-a-glance legibility) and Apple Maps/Waze in-car layout norms.

---

## Summary

Two distinct problems are tangled in Kevin's one sentence, and they have different fixes. The **color problem is real and measurable**: the Drive Mode chips render severity text at full saturation on top of a *tint of that same color* — a pattern that computes to roughly **1.4–2.6:1 contrast in Light Mode** (all three severities fail WCAG AA's 3:1 large-text floor) while the identical pattern computes to **~9.8:1 in Dark Mode**. The palette wasn't tuned wrong for dark rooms; it was tuned only for dark rooms, and daylight driving — the actual product context — is where it breaks. The **layout problem is a coordination gap, not a density gap**: eight PRs each added one more independently-positioned floating element (End Drive pill, Report button, Park Here button, Recenter pill, Park Until pill, approaching strip, two toolbar clusters) with no shared spacing system, and at least one of those elements (the Recenter pill) has no coordinated clearance from the bottom card it can render directly on top of. Both problems have concrete, bounded fixes below; neither requires a redesign.

---

## Findings

### P1 — Visibility / safety-critical

#### P1-1. Chip severity text is nearly unreadable in Light Mode — computed contrast ~1.4–2.6:1

**Where:** `ios/WePark/WePark/Views/DriveModeBottomCard.swift:178–195` (`chipBackgroundColor` / `chipTextColor`), sourcing `ios/WePark/WePark/Services/ParkingColors.swift:15–39`.

**What:** Each chip's background is `severityColor.opacity(0.15)`; its text is the *same* `severityColor` at full opacity. Both sit on top of `.regularMaterial` (line 86), which in Light Mode blends toward a near-white backdrop.

Computed (WCAG 2.1 relative-luminance formula, assuming a `.regularMaterial` blend toward `#F2F2F7`, the standard iOS grouped-background tone):

| Severity | Chip text (full color) | Chip background (15% tint) | Contrast ratio | WCAG AA (normal text, 4.5:1) | WCAG AA (large text, 3:1) |
|---|---|---|---|---|---|
| Metered (amber `0.92,0.76,0.0`) | #EBC200 | ~#F1EBD2 | **1.43:1** | Fail | Fail |
| Free (`Color.green`) | #34C759 | ~#D5ECDF | **1.79:1** | Fail | Fail |
| Restricted (`Color.red`) | #FF3B30 | ~#F4D7D9 | **2.63:1** | Fail | Fail (barely) |

By contrast, the same amber used *correctly* elsewhere in this codebase — `ASPBanner.swift:77` (`.aspInEffect`: solid amber background, near-black text at `Color(red:0.15, green:0.10, blue:0.0)`) — computes to **~9.95:1**, and in Dark Mode the *chip's own* tint-on-tint pattern computes to **~9.8:1** (dark material backdrop + bright saturated text = high contrast). The pattern isn't broken in the abstract; it's broken specifically for a light backdrop, which is the daylight-driving case Kevin is testing in.

**Why it matters:** This is the literal thing Kevin flagged — "color scheme can be improved for visibility" — during a *daytime* drive-test. A driver glancing at the chip for 1–2 seconds at a stoplight, in direct sun, with a windshield glare on the screen, is reading text at ~1.4–2.6:1 contrast. That's below the threshold most people can reliably parse even stationary and indoors, let alone at speed.

**Recommendation:** Switch chips to a **solid-fill badge**, matching the already-correct `ASPBanner` pattern:
- Background: full-saturation severity color (no `.opacity()`).
- Text: `Color.white` for red/green (both dark enough), and a near-black custom color (e.g. `Color(red: 0.15, green: 0.10, blue: 0.0)` — reuse the exact value `ASPBanner` already uses) for the amber metered chip, matching `ASPBanner`'s existing amber-on-dark-text pairing exactly.
- Keep `cornerRadius: 10`, keep `.opacity(0.15)` background only for the `.unknown` case (which already uses a system color, not a tinted-self color, and is fine).

This is a ~10-line change confined to `chipBackgroundColor`/`chipTextColor` — no layout restructuring needed.

**Effort:** ~1 hour (color values) + re-verify in both Light and Dark Mode on device.

---

#### P1-2. Drive Mode chips silently drop the "restriction coming soon" (orange) tier that exists everywhere else in the app

**Where:** `ios/WePark/WePark/Models/SafetyLabel.swift:27–40` (`Severity` enum: only `free`/`metered`/`restricted`/`unknown` — no coming-soon case), `ios/WePark/WePark/Services/DrivingContextService.swift:63–72` (`SideOpportunity` enum, same 4-case shape), `Services/ParkingRulesEngine.swift:123,127` (`safetyLabel(for:at:)` maps a segment with a restriction starting inside the 6-hour `nearFutureWindow` straight to `severity: .free` — the *text* says "Free until 9:30am" but the *severity* used for chip color is indistinguishable from "Free, nothing coming for days").

Compare to the main browsing map, which has a 5th, distinct state precisely for this: `Models/CurrentState.swift:22` `freeButRestrictionSoon` → orange (`docs/design/ios-mvp-palette.md` §2.1, row 2 — "Warning state... driver gets the 'be careful, set a timer' signal at a glance"). That orange tier was a deliberate, documented design decision for the *browsing* map. Drive Mode — the one surface where the driver is actually looking at the screen while approaching a spot — never got it.

**Why it matters:** A driver glancing at a green "Free — check signs" chip has no visual signal that the block goes red in 20 minutes. The orange tier exists specifically to prevent this — "fine for a quick errand, not safe to leave the car" — and it's present on the map nobody looks at while driving, and absent from the card everybody looks at while driving. This is a genuine information-hierarchy inversion, and it's exactly the kind of thing "the color scheme can be improved" is pointing at even if Kevin can't name the mechanism.

**Recommendation:** Add a `.comingSoon` case to `SideOpportunity` and `SafetyLabel.Severity`. In `aggregateSide` (`DrivingContextService.swift:406–445`), when a segment's *severity* is `.free` but `engine.currentState(for:at:)` for that same segment resolves to `.freeButRestrictionSoon`, classify the side as `.comingSoon` instead of short-circuiting to `.free`. Chip color: reuse `ParkingColors.restrictionComingSoon` (`Color.orange`) with the same solid-fill treatment from P1-1 (`Color.orange` background, white or near-black text — check contrast, orange is mid-luminance so verify against both).

**This should land in the same PR as TF2-17** ("Free until X" copy) — both touch `aggregateSide`/`SafetyLabel` construction, and TF2-17's whole point is surfacing the *time* of the next restriction; pairing it with the *severity tier* that already exists to represent "restriction imminent" is the same piece of work, not two.

**Effort:** ~2–3 hours (new enum case + `aggregateSide` branch + chip color mapping + a few new tests mirroring the existing `TF27Tests` pattern). Sits naturally inside the TF2-17 PR.

---

#### P1-3. Recenter pill has no coordinated clearance from the bottom card — likely overlaps it

**Where:** `ios/WePark/WePark/ContentView.swift:1456–1472` — the "Recenter" pill (shown when `followPaused == true`) is positioned with a hardcoded `.padding(.bottom, 8)` inside `driveModeOverlayLayer`, a `ZStack` sibling (line 1041: `if driveModeActive { driveModeOverlayLayer }`) that is **not** wrapped by the `.safeAreaInset(edge: .bottom) { bottomSafeAreaContent }` modifier attached to `mapRepresentable` (line 1035) — the modifier that actually reserves screen space for `DriveModeBottomCard` + the optional approaching strip + the optional `ParkUntilPill`.

Because the Recenter pill's `VStack` uses a `Spacer()` to push it to the bottom of `driveModeOverlayLayer`'s own frame (not the frame *above* the safe-area-inset content), it has zero awareness of how tall `bottomSafeAreaContent` currently is. That height is **not fixed** — it grows when the approaching strip appears (`DriveModeBottomCard.swift:68–82`, +~30pt) and again when `ParkUntilPill` is also showing (`ParkUntilSheet.swift:265–288`, +~50pt with margins).

This is the exact bug class that was already found and fixed *at the top* of the screen: `endDrivePillTopPadding` / `paddingForBannerState` (`ContentView.swift:2474–2489`) exists specifically because the End Drive pill needed coordinated clearance from the ASP banner (W8.5c-polish PR-1, per `HANDOFF.md`). The equivalent fix was never applied at the bottom.

**Why it matters:** Recenter is the control a driver reaches for immediately after they've panned the map away from their position — i.e., exactly when they're not looking at the road and want one clean tap. If it renders overlapping or crammed against the top of the DriveModeBottomCard (most likely scenario: cruise mode + approaching strip active + user just panned), it's either mis-tappable or visually merges into the chip row it's supposed to sit clear of.

**Recommendation:** Mirror the existing `paddingForBannerState` pattern. Either (a) move the Recenter pill *inside* `bottomSafeAreaContent`, positioned above `DriveModeBottomCard` in the same `VStack`, so it naturally stacks with coordinated spacing and never needs manual height math, or (b) if it must stay in the overlay layer for z-order reasons, compute its bottom padding as a function of `showApproachStrip` + `parkUntilMode` the same way `endDrivePillTopPadding` is computed from `bannerState` — e.g. a `recenterPillBottomPadding` pure function returning `88` (base card) `+ 30` (approach strip) `+ 58` (Park Until pill) as applicable, following the same "hardcode the known heights" approach already validated for the top pill.

**Effort:** ~2–3 hours including a device check across the 4 combinations (card alone / card+strip / card+pill / card+strip+pill).

---

### P2 — Significant (degrades UX, not blocking)

#### P2-1. Top action row crams 4 differently-styled buttons with inconsistent sizing into one HStack

**Where:** `ContentView.swift:1328–1454` (`driveModeOverlayLayer`'s top `HStack`): "End Drive" (red capsule, `Label`, auto-height via padding — no explicit `minHeight`), mute toggle (cruise-only, explicit `44×44` square), "Report" (orange rounded-rect, icon-over-caption2-label internal layout, explicit `frame(minWidth: 44, minHeight: 44)`), "Park here" (accent-color capsule, auto-height via padding).

**Why it matters:** Four buttons, three visual shapes (capsule / square / rounded-rect-with-stacked-content), three accent colors (red / orange / accent-blue), two different internal sizing strategies (explicit frame vs. padding-implied) in a single horizontal row. This is very plausibly the single biggest contributor to "layout is clunky" — it's the row a driver sees on every single Drive Mode screen, and it doesn't read as one coherent toolbar.

**Recommendation:** Pick one button anatomy and apply it to all four: recommend the capsule-with-`Label`(icon + text) style already used for "End Drive" and "Park here" — it's the most legible at a glance (text label, not icon-only). Convert "Report" to `Label("Report", systemImage: "flag.fill")` in capsule form instead of the vertical icon-over-caption2 stack; convert the mute toggle similarly or keep it icon-only but give it the *same* height as the others via `.frame(minHeight: 44)` explicitly on every button (not implied by padding). Standardize spacing to `spacing: 10` between all four.

**Effort:** ~2 hours.

---

#### P2-2. Two Drive Mode toolbar clusters float at different vertical offsets (44pt vs. 100pt from top)

**Where:** `recenterButtonStack` (`ContentView.swift:1036–1038`, `.padding(.top, 100)`) vs. `driveModeOverlayLayer`'s top row (`ContentView.swift:1454`, `.padding(.top, endDrivePillTopPadding)` = fixed `44`).

**Why it matters:** During Drive Mode, both clusters are visible simultaneously — the left cluster (End Drive / Report / Park Here) sits ~56pt higher than the right cluster (Find me / Find my car / Park Until / resting drive icon). They're conceptually peers ("controls available right now") but read as two unrelated toolbars bolted on at different times — because they were: the right cluster predates Drive Mode (W5.1) and the left cluster was added in W8.5c/TF2-7 without reconciling against it.

**Recommendation:** Give both the same top offset. Simplest fix: change `endDrivePillTopPadding` / `paddingForBannerState` to return `100` (matching the existing recenter-stack constant) instead of `44`, since `100` already accounts for status bar + ASP banner clearance in practice (it's been live and correct for `recenterButtonStack` this whole time). Verify the ASP-banner-clearance intent of `paddingForBannerState` is still satisfied at `100` (it will be — `100 > 44`).

**Effort:** ~30 minutes + device screenshot verification.

---

#### P2-3. Three independently-styled floating systems can stack at the bottom of the screen with no shared visual language

**Where:** `bottomSafeAreaContent` (`ContentView.swift:1160–1181`) stacks `DriveModeBottomCard` (edge-to-edge `.regularMaterial` slab, hairline top divider, no side margins) directly above `ParkUntilPill` (`ParkUntilSheet.swift:265–288` — an *inset* capsule with `16pt` side margins and its own `.regularMaterial` background) in the same `VStack`. Independently, the Recenter pill (P1-3) is a third floating capsule with no shared margin/corner-radius token.

**Why it matters:** Cruise Mode + Park Until filter + a paused follow (a realistic combination — someone opens the time filter while circling for a spot, then pans to look at a block) puts three different "card" shapes on screen at once with no unifying rhythm: one flush-edge rectangle, two inset capsules, none sharing a margin or corner-radius convention.

**Recommendation:** After fixing P1-3, define one shared bottom-stack convention: all floating bottom elements get `16pt` side margins and `8pt` vertical gaps (matching `ParkUntilPill`'s existing values, since that one is already correct), OR make `DriveModeBottomCard` visually match by insetting it too. Pick one; don't leave both.

**Effort:** ~1–2 hours, mostly verification once P1-3 is fixed (they're the same underlying issue: nobody owns "the bottom stack" as a single layout unit).

---

#### P2-4. Color collision: ASP-banner amber and metered-chip amber are the identical hex, used for two different meanings

**Where:** `ASPBanner.swift:77` (`.aspInEffect` background) and `ParkingColors.swift:29` (`meteredActive`) both use `Color(red: 0.92, green: 0.76, blue: 0.0)`.

**Why it matters:** These can both be on screen at once in Drive Mode (banner always-on at top; a metered chip in the bottom card). The banner amber means "street cleaning is scheduled today, day-level fact, unrelated to this specific block." The chip amber (after the P1-1 fix, a *solid* amber badge) means "this side of the street is metered, pay to park, right now." Same color, adjacent on screen, different question answered. This is a smaller ask than the other findings — flag it as a decision for Kevin rather than silently resolving it, since "amber = pay attention / costs something" is a defensible unifying theme and might be intentional-enough to keep.

**Recommendation:** Either (a) accept the overlap as thematically consistent ("amber = costs you something, in different ways") and do nothing, or (b) shift the metered chip to a distinguishable amber variant (e.g., a warmer/more saturated amber, or add a small `$` / meter SF Symbol inside the chip so the two ambers are never read as "the same fact twice"). Recommend raising this as a one-line question in the engineer-pass PR description rather than resolving it unilaterally.

**Effort:** 0 (decision only) or ~1 hour if (b) is chosen.

---

#### P2-5. Chip layout is already near capacity today; TF2-17's longer copy will make it worse

**Where:** `DriveModeBottomCard.swift:126–130` (two chips, `HStack(spacing: 12)`, each `frame(maxWidth: .infinity)`) and `:161–167` (`.lineLimit(2)` + `.minimumScaleFactor(0.75)` as the overflow strategy).

At a 390pt-wide iPhone: `390 − 32 (card horizontal padding) − 12 (HStack spacing) = 346`, so each chip gets ~173pt, minus its own `12pt`-per-side internal padding → **~149pt of text width per chip**. Current copy ("Free — check signs" / "Metered" / "No parking") mostly fits on one line. TF2-17's target copy ("Free until Thu 9:30am") is longer and will routinely wrap to 2 lines, triggering the `0.75` scale-down floor.

**Why it matters:** Two-line, shrunk-to-75%-scale text inside a half-screen-width chip is close to the opposite of "readable in 1–2 seconds at a stoplight." This is explicitly flagged because TF2-17 is landing concurrently — the chip layout needs to be re-evaluated *before*, not after, longer strings ship, or Kevin will file a second, harder-to-diagnose "text too small" ticket.

**Recommendation, in order of preference:**
1. **Stack chips vertically** (Left row full-width, Right row full-width, instead of side-by-side) when Drive Mode text is long. Full card width (~358pt after padding) comfortably fits "Free until Thu 9:30am" on one line at `.subheadline`. Costs ~24pt more card height (one extra row) — acceptable given the approaching strip already adds height conditionally.
2. If side-by-side must be preserved for width reasons, raise the `minimumScaleFactor` floor from `0.75` to `0.9` (never let text shrink below 90% — a 25% shrink is where legibility actually breaks at a glance) and drop `lineLimit` to `1` with a trailing truncation (`.truncationMode(.tail)`) rather than wrapping to 2 lines — a truncated-but-full-size single line reads faster than a complete-but-tiny two-line block.

**Effort:** ~2–3 hours if option 1 (stacked layout), ~30 minutes if option 2 (parameter tuning only). Should land in the same PR as TF2-17 since the copy change is what triggers the need.

---

#### P2-6. Sign-check checklist checkbox is under the 44×44pt touch-target minimum

**Where:** `ios/WePark/WePark/Views/SignCheckConfirmView.swift:196–205` — the checkbox glyph is `Image(systemName:)` at `.font(.system(size: 22))` with `.onTapGesture`, no explicit `frame`. Actual hit area ≈ 22×22pt.

**Why it matters:** Below Apple HIG's 44×44pt minimum interactive-element size (`developer.apple.com/design/human-interface-guidelines/layout`). Low real-world severity since the checkboxes are explicitly optional/non-gating (the "I checked — Park here" button is the real gate), but it's still an interactive element that will mis-tap, and it's on a screen presented right before a park-here confirmation — a moment worth getting right.

**Recommendation:** Wrap in a `Button` (gets built-in accessibility + larger effective hit area) with `.frame(width: 44, height: 44)` around the glyph, `.contentShape(Rectangle())` so the full 44pt square is tappable, not just the 22pt glyph.

**Effort:** ~20 minutes.

---

### P3 — Polish

#### P3-1. "End Drive" / "Park here" pills lack explicit `minHeight: 44`
Relying on `subheadline` font + `10pt` vertical padding to clear 44pt is close but not guaranteed at all Dynamic Type sizes. `ContentView.swift:1339–1348`, `:1441–1448`. Add explicit `.frame(minHeight: 44)`. ~15 minutes.

#### P3-2. Three different corner radii across one feature surface
Chips use `cornerRadius: 10` (`DriveModeBottomCard.swift:172`), sheet CTAs use `cornerRadius: 14` (`ArrivalPromptSheet.swift:91,105`; `SignCheckConfirmView.swift` via `.buttonStyle(.borderedProminent)` default), sheets themselves use `.presentationCornerRadius(20)` throughout. Not wrong individually, but an unrehearsed detail across "one thing." Consider a single Drive Mode corner-radius scale (e.g., `10` for chips/buttons, `20` for sheets — already 2 of the 3 values in use, just standardize the `14`). ~30 minutes, cosmetic only.

#### P3-3. Street name + distance indicator + mute button crowding risk
`DriveModeBottomCard.swift:103–122` — three elements share one row. Currently mitigated via `.lineLimit(1)` + `.minimumScaleFactor(0.8)` on the street name, which should degrade gracefully, but worth a real-device check with a long name ("FREDERICK DOUGLASS BLVD") + destination distance both showing simultaneously. No code change recommended unless the device check finds a problem.

---

## What's working

- **`ASPBanner` is the model to copy, not just a comparison point.** Solid full-saturation fill + high-contrast text (computed ~9.95:1), state-driven color and copy, a complete-sentence `accessibilityLabel`, and a deliberate no-dismiss decision because the underlying fact is ground-truth for the whole day. Every chip-contrast fix above is "make the chips work like the banner already does."
- **44×44pt touch targets are correctly implemented where someone thought about it** — the mute button (`DriveModeBottomCard.swift:230–246`) has an explicit comment calling out the HIG minimum and a deliberate 44pt invisible tap frame around a 36pt visual glyph. That's the right pattern; it just wasn't applied everywhere (P2-6, P3-1).
- **No webview tells.** SF Symbols throughout, system fonts via `.headline`/`.subheadline`/`.caption` rather than fixed point sizes, native `Menu`/`confirmationDialog`/`.sheet` — this reads as a native app. Dynamic Type is respected structurally; the TF2-17 chip-capacity risk (P2-5) is a spacing/line-limit tuning problem, not a "hardcoded 12pt font" problem.
- **`SignCheckConfirmView`'s opaque-background fix (TF2-9) is exactly right.** Wrapping the sheet in `Color(.systemBackground)` to guarantee opacity regardless of `.presentationBackground` material behavior, plus wrapping the checklist in a `ScrollView` so it never clips at large Dynamic Type sizes — this is careful, defensive engineering on a sheet that has to remain legible while floating over a translucent Drive Mode surface.
- **The resting-vs-in-drive long-press split** (Tier 3 sub-PR #2 — `confirmationDialog` for resting map taps, dedicated in-drive Report button for driving taps) is a clean, native pattern that correctly recognizes driving and browsing need different affordances for the same underlying action.
- **The side-aggregation simplification itself (TF2-7) is sound** — reducing zone-by-zone segment detail to one actionable "is there parking on this side" answer per side is the right instinct for glanceability. The only gap is that it over-simplified by one tier (P1-2) — the fix is additive (bring back one case), not a rethink of the aggregation approach.

---

## Suggested single engineer-pass scope

Bundle the following into **one PR, timed with TF2-17** (both already touch `DrivingContextService.aggregateSide` / `SafetyLabel`, so splitting them would mean touching the same functions twice):

1. **P1-1** — solid-fill chip badges (color values only, `DriveModeBottomCard.swift`).
2. **P1-2** — restore the `.comingSoon` orange tier to `SideOpportunity`/`SafetyLabel`/chip mapping. *This is where TF2-17's "Free until X" work naturally lives* — the two changes are one refactor of `aggregateSide`.
3. **P2-5** — chip layout: prefer stacked Left/Right rows to make room for TF2-17's longer strings; at minimum, raise `minimumScaleFactor` to `0.9` and switch to single-line truncation.
4. **P1-3** — Recenter pill coordinated clearance from the bottom card (mirror `paddingForBannerState`).
5. **P2-2** — unify the two top-toolbar vertical offsets (`44` → `100`, one-line change).
6. **P2-1** — normalize the 4-button top action row to one button anatomy (capsule + `Label`, `minHeight: 44` explicit on all four).
7. **P2-6** — checkbox tap target fix in `SignCheckConfirmView` (trivial, same-surface bundle-of-convenience).

**Leave out of this pass, flag as an explicit decision point in the PR description:**
- **P2-4** (amber collision) — needs a yes/no from Kevin on whether the shared amber is a feature or a bug before touching it.
- **P2-3** (bottom-stack shared margin convention) and **P3-2** (corner-radius standardization) — do a quick pass once P1-3/P2-5 land and the bottom stack is visually re-verified; likely folds into the same device-check pass for near-zero extra cost, but isn't independently worth a second PR.

**Estimated total for the bundled 7 items:** ~1.5–2 sessions (one for the color/severity/copy work items 1–3, which needs its own test coverage since it touches `aggregateSide`; half a session for the layout-coordination items 4–7, which are mostly constant/padding changes plus a device-screenshot verification pass across the four bottom-stack combinations called out in P1-3).
