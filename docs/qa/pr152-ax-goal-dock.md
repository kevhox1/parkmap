# PR #152 AX goal dock QA Pass 1 — 2026-11-23

**Reviewed:** branch `feat/ax-goal-dock` at `f3b3e92b`, against `docs/design/goal-first-ambient-design.md` ("Addendum — accessibility-size goal dock") and the PR body.
**Verdict:** MERGE-WITH-FOLLOWUPS (feature is dark behind `driveModeDefaultEnabled=false`; no blocking defects; the follow-ups are the with-banner budget gap already routed to the designer plus two coach/banner collisions at the extreme sizes).

Environment: iPhone 17 sim (402x874), dark mode, location Manhattan (West Village 40.7339,-74.0040 for street data; MSG 40.7506,-73.9935; East Village 40.7265,-73.9815). `driveModeDefaultEnabled` and `onboardingStoryEnabled` flipped locally for the flags-on build, discarded afterward (`git checkout -- ios/WePark/WePark`). Each check is tagged LIVE (observed on the sim via `axe describe-ui` frames + screenshots that I read) or CODE (read only).

## Summary
The two-row dock (Start Driving + one goal card -> local goal sheet) works as specified at AX1-AX5: the card shows the right copy and a11y label, the sheet opens at both detents, picking a tile dismisses it and changes the goal (and the map recolors live), closing without choosing leaves everything alone, and the coach bubble hides while the sheet is up and RETURNS after Done or swipe-down. No-banner dock budget is comfortably met (27.7-29.5%). Flag-off is the legacy UI; `large` is unchanged (dock 266pt). Remaining issues: with-banner budget (ruling 3, measured below), the 45% safety clamp lets the "Park here?" card cover the banner text at AX2, and coach mark 2 at AX5 overflows into the banner and Start Driving.

## Budget table (measured by me, LIVE, `describe-ui` frames; dock = 874 - Start Driving top; screen 874pt)

| Size | Banner | Goal | Dock pt | Dock % | ASP top banner | Map band (874 - banner - dock) |
|---|---|---|---|---|---|---|
| large (AX0) | none | Overnight | 266 | 30.4% | 104 | 504 (58%) |
| AX1 | none | Overnight | 256 | 29.3% | 116 | 502 (57%) |
| AX1 | none | Park & Forget | n/m (PR: 319; not re-measured) | | | |
| AX3 | none | Overnight | 242 | 27.7% | 129 | 503 (57%) |
| AX3 | none | A Few Hours / Park & Forget | 258 | 29.5% | 129 | 487 (56%) |
| AX5 (type frozen at AX3 by cap) | none | Overnight | 242 | 27.7% | 203 | 429 (49%) |
| AX1 | "No clear spots..." (Park & Forget) | P&F | 441 (banner top 433) | 50% | 116 | ~317 (36%) |
| AX2 | same | P&F | 518 (banner top 356) | 59% | 122 | ~234 (27%) |
| AX3 | same | P&F | 432 (banner top 442) | 49% | 129 | ~313 (36%) |
| AX5 | same | P&F | 432 | 49% | 203 | ~239 (27%) |

Dock <= 40% / map >= 35% is MET at every size without a banner. With the empty-map banner, the budget is NOT met (ruling 3; numbers match the PR's 441/518/432/432). Best case map band 27% at AX2 and AX5.

## Acceptance criteria checklist

- [x] `large`: dock unchanged, three tiles across, 266pt — LIVE (Start Driving top 608; screenshot shows 3 tiles).
- [x] AX1/AX3/AX5: two-row dock (Start Driving + goal card) — LIVE.
- [x] Dock <= 40%, map >= 35% without banner — LIVE (table).
- [ ] Dock <= 45% / map >= 30% with banner — NOT MET (ruling 3; see finding #1). Not blocking per orchestrator.
- [x] Card copy: goal name, sub-label at AX1/AX2, dropped at AX3+; "Change" + chevron up to AX2, chevron only at AX3+ (ruling 2) — LIVE (AX1 shows Change, AX3/AX5 chevron only; PR deviation: AX2 `P&F` card still shows Change + sub-label and was 214pt tall).
- [x] Card a11y label "..., Selected. Double tap to change goal." and button role — LIVE for the label and `role: button` in describe-ui; the `.isButton` trait itself is CODE (AXe reports `traits: []` for every element, so traits cannot be read here).
- [x] Card -> local sheet, both detents (medium, large), drag indicator, Done, nav title "Pick a parking goal" — LIVE at AX5 (medium shows one tile + peek of the second; large scrolls; third tile runs past the screen, ScrollView).
- [x] Nothing truncates in the sheet at AX5 — LIVE (names wrap at word boundaries, sub-labels wrap; "Won't need to move it" wraps to 2 lines).
- [x] Selected sheet tile has checkmark — LIVE. `.isSelected` trait — CODE only (`.accessibilityAddTraits(isSelected ? [.isSelected] : [])`; AXe cannot show traits). Note the selected tile's label does not say "selected" textually, so VoiceOver relies on the trait.
- [x] Pick dismisses the sheet and changes the card — LIVE (Overnight -> A Few Hours -> Park & Forget). Haptic — CODE (`.sensoryFeedback(.selection, trigger: selectedGoal)` stays mounted on the dock VStack; fires on selection change).
- [x] Map recolors after pick in Manhattan — LIVE: with coach mark 2 showing after picking A Few Hours in the West Village, green block-face lines appear that were all red under Overnight. (Caveat: earlier P&F screenshots in the same area were all red; I believe that is data, not wiring, since the pick path is the same `selectGoal` closure as the tile tap — CODE.)
- [x] Close without choosing (Done and swipe-down): card stays, selection unchanged — LIVE (Done during coach; swipe-down during coach). Coach bubble returns after both — LIVE (this was the untested item).
- [x] Coach AX3: mark 1 card copy "Tap the goal card to pick what you need", ring on the card — LIVE. Tapping the card opens the sheet and hides the bubble — LIVE. Picking in the sheet advances to mark 2 above the dock, ring on card — LIVE. Mark 2 at AX3 overlaps no banner — LIVE (see finding #3 for AX5).
- [x] Long-press "Park here?" at AX1/AX3/AX5 sits above the dock, both buttons tappable — LIVE (Park here/Cancel bottoms at 590/604/604 vs dock tops 618/632/632; Cancel tapped by label at each size).
- [~] Empty-map banner at AX sizes — LIVE triggered (Park & Forget at a no-data location, text "No clear spots found very nearby — try Overnight, or pan the map."); measured above; harm in findings #1-#2.
- [x] VoiceOver label/role — see above. Focus return after sheet close — CODE only, not verified (SwiftUI default).
- [x] Flags back to false, rebuild: legacy UI (Report pill, search sheet, map key), no goal dock — LIVE (AX3 screenshot).

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
- **#1: With-banner budget not met (known, ruling 3, going to the designer)**
  - Where: `GoalSelectorView.body` banner + dock VStack
  - What: dock 49-59% of screen with the empty-map banner, map band as low as 234pt (27%) at AX2; pinned only by the 62% ceiling test. Functional harm observed: none of the tap targets are hidden (Search/More/Recenter stay above the banner, Start Driving and card fully visible), but the live map area to pan is under a third of the screen. Matches the PR's numbers.
  - Expected: <= 45% dock / >= 30% map.
  - Repro: Park & Forget at a location with no clear spots (e.g. 40.61,-74.05 sim location), content size accessibility-large.
  - Owner: `@designer` then `@ios-engineer`.
- **#2: 45% safety clamp lets the "Park here?" confirm card overlay the empty-map banner at AX2**
  - Where: `ambientOverlayBottomPadding` (`min(clearance, containerHeight * 0.45)`), used for `longPressParkConfirmOverlay`
  - What: with the banner at AX2 (dock ~518pt = 59%), clearance is clamped to 45%, so the card (y 371-474) sits on top of the banner (y 356-520) and covers the banner's first lines. Both buttons are tappable (card is on top), so no functional loss, but banner text is hidden. The PR's comment says the clamp "no longer binds"; it does bind in this case.
  - Expected: card clear of the dock, or banner not obscured.
  - Repro: AX2, Park & Forget at an empty location, long-press the map.
  - Owner: `@ios-engineer` (fix likely rides along with the banner decision in #1).
- **#3: Coach mark 2 at AX5 overflows: covers the ASP banner, Skip collides with banner text, bubble sits on top of Start Driving, body copy clipped ("you'll have" ... "to move it." scrolled)**
  - Where: `OnboardingCoachOverlay` mark 2 region at AX5 (real size, uncapped by design)
  - What: with the 203pt ASP banner + dock top at 616, the available band is too small for the AX5 type; the bubble (y 226-674) spans from the banner to the dock top and the Skip pill overlaps the banner copy "Today". Got it is reachable; text scrolls internally per the overlay's fallback. This is the PR's own "min-region-height fallback". Observed by switching to AX5 mid-coach; I did not do a cold launch at AX5.
  - Expected: bubble in clear space or capped type for the bubble.
  - Owner: `@ios-engineer`.

### 🟢 Minor / nit
- **#4:** Coach mark 1 bubble at AX3 overlaps the top of the More button (bubble right edge ~360pt vs More x 330-386, bubble top 253 vs More y 230-286). Also mark 2. Dismissable controls still reachable via Got it/Skip.
- **#5:** Medium detent at AX5 shows only one full tile plus a sliver of the second; the other two goals are discoverable only by scrolling/pulling to large. Acceptable, maybe default to `.large` at AX4+.
- **#6:** The goal card's "Change" word and sub-label still show at AX2 where the card measured 214pt (P&F, banner scenario) — consistent with the spec threshold (< AX3), just tall.

### 💡 Out of scope (logged, not fixed)
- The top ASP banner at AX5 (203pt) overlaps the Search button (y 162-218): pre-existing, not touched by this PR.
- "Cancel" wraps mid-word ("Can-cel") in the long-press card at AX5: pre-existing (PR deviation 5).
- Map labels (e.g. "The Rutherford") draw behind the Search/More buttons: Apple Maps label layer, pre-existing.
- Not verifiable here: VoiceOver focus return after sheet close; SE / Pro Max budgets; Reduce Motion; `.isSelected` / `.isButton` traits (AXe shows empty traits for all elements).

## Code review (CODE)
- Sheet state is local to `GoalSelectorView` (`@State goalSheetPresented`), not `activeSheet`; `ContentView` only mirrors it via `onGoalSheetPresentedChange` -> `goalSheetPresented`, used solely to hide the coach bubble. OK. Guards: `.onChange(of: usesGoalCard)` closes the sheet if size drops below AX1; `.onDisappear` clears the mirrored flag. OK.
- `.dynamicTypeSize(...accessibility3)` is on the dock VStack only; `.sheet` is attached after it so the sheet scales past AX3 (confirmed LIVE: sheet text larger than card at AX5). Banner capped separately at AX2 inside the dock. OK.
- No change below AX1: `goalDockUsesGoalCard` requires `isAccessibilitySize`; `DockButtonFrame` keeps 56 below AX1; `StartDrivingRow` non-AX branch identical. `large` measured 266pt LIVE. OK.
- `mapZStack` child count unchanged: the ContentView diff only adds a state var, an `!goalSheetPresented` condition inside the existing coach `if`, a closure argument and a doc comment. OK.
- Flag-off guards: `GoalSelectorView` only mounts via the unchanged `goalSelectorDockVisible(driveModeDefaultEnabled:...)` gate; flag-off build LIVE shows the legacy UI. OK.
- Overlay padding uses the measured dock frame (`onboardingGoalDockFrame`), unchanged logic; the 45% clamp binds only in finding #2's case.
- Frame readout staleness while the sheet covers the dock: the dock stays mounted and laid out under the sheet (sheet is local, `activeSheet` stays nil), the coach frames carry the goal key so a selection change re-fires, and the bubble is hidden while the sheet is up. No staleness observed (mark 2 ring landed on the card after the pick). OK.
- Haptic: `.sensoryFeedback(.selection, trigger: selectedGoal)` retained on the dock VStack; fires for sheet picks. CODE only.

## Smoke tests run
- Built flags-on (`xcodebuild`, own derived data), installed on an iPhone 17 sim, location Manhattan. Screenshots read at large, AX1, AX3, AX5; sheet medium + large at AX5; pick flows; coach marks 1 and 2 at AX3 and mark 2 at AX5; long-press card at AX1/AX3/AX5 and with banner at AX2; empty-map banner at AX1/AX2/AX3/AX5; flags-off rebuild at AX3.
- Not run: the full test suite (CI ran it), SE/Pro Max, device VoiceOver.
- Disk: 8.2 GB free at start; derived data deleted afterward.

## What's working
- The no-banner dock is compact (27-30%) at every AX size and the card tap/sheet/pick loop is clean and legible at AX5.
- The coach integration is well thought out: hide while the sheet is up, return on Done or swipe, advance to mark 2 after a pick, ring on the card, card-specific copy.
- Flag-off and `large` are untouched; the diff is contained to the dock view and small, gated ContentView hooks.
