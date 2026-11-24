# PR #156 pre-flip polish batch: live QA (2026-11-23)

**Reviewed:** `polish/preflip-batch-2026-11-23` merged locally with current `origin/main` (includes PR #157). Merge was clean (mergeable/CLEAN, no conflicts). Built Debug for iOS Simulator (BUILD SUCCEEDED, warnings only), flags `driveModeDefaultEnabled`, `curbPinPlacementEnabled`, `onboardingStoryEnabled` local-only (reverted). iPhone 17 (iOS 26.5) and iPhone SE 3rd gen (iOS 26.5). No tests run (build only, per brief).

**Verdict: MERGE** (one pre-existing AX-card finding logged as a follow-up, not caused by this PR)

## Per-item results

| # | Item | Result | Evidence |
|---|------|--------|----------|
| 1 | Curb-pin card cross streets title-cased | PASS | East Village, E 2nd St: card reads "E 2 St · North side" / "between Ave A & 1 Ave" (was "AVE A & 1 AVE"-style canonical). `assets/pr156/item1-curbpin-card.png`. Ordinals stripped ("1 Ave") as documented, not flagged. FDR-acronym case NOT seen live (no FDR block tried); covered only by the PR's unit test, not run by me. |
| 2 | More sheet `.large` detent | PASS | Opens at medium (Settings not visible); swipe-up on handle expands to large; all 7 rows incl. Settings fully visible with no scroll. `item2-more-large.png` |
| 3 | Settings Done dismisses | PASS | Done present in nav bar; pushed Parking 101 still shows its back chevron (no Done conflict); Done closed the sheet back to the ambient map. `item3-settings-done.png` |
| 4 | Coach mark 1 clears user dot | PASS (default size), AX unchanged | See below. `item4-mark1-default.png`, `item4-mark1-ax3.png` |
| 5 | N2 doc note | PASS (read) | As-built note dated 2026-11-23 present in `docs/design/first-run-onboarding-design.md`. |
| 6 | Goal tiles never split mid-word | PASS | SE XXXL: "Overnight" whole (slightly shrunk), "A Few / Hours", "Park & / Forget". SE XXL: same, whole. iPhone 17 at Large: dock layout looks like main, "Overnight" whole, tiles unchanged. `item6-se-xxxl.png`, `item6-se-xxl.png`, `item6-iphone17-large-dock.png` |

### Item 4 detail
Cold run: all three onboarding keys deleted, app uninstalled/reinstalled (deleting keys alone left the app in the "upgrading install" path where the story deck is pre-seeded as seen and the coach is skipped for the story cover; a true cold start needs `wepark_has_launched_before` absent too). Story deck appeared, tapped Skip, coach mark 1 mounted. The bubble's bottom edge sits clearly above the blue dot (about 60 px gap at 3x) at 3 s and again at 7 s. Location was already set and permission pre-granted, so the camera was already on the user when the overlay first rendered. I did not exercise the engineer's caveat case (camera recentering AFTER the overlay renders, e.g. with the priming card path and a late first fix): **not verified, recommend a device cold-install check** (permission prompt, then late fix).
AX (accessibility-large, AX3): mark 1 is the bottom-aligned card layout above the dock, dot not avoided (by design, "skipped at AX"); layout looks like PR #153 rules, nothing broken by this PR.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
None attributable to this PR.

### 🟢 Minor / follow-up
- **#1 (pre-existing, not in this PR): AX goal card still breaks "Overnight" mid-word.** At accessibility-large on iPhone 17 the selected goal card (Change layout) renders "Overnigh / t" (see `item4-mark1-ax3.png`). PR #156 explicitly leaves the AX1+ card path untouched, so this is outside its scope; the same fix (word-boundary / shrink) should be applied to the AX card. Owner: `@ios-engineer`.
- **#2 (nit):** At XXL/XXXL on SE the selected "Overnight" tile is shorter than its two neighbours (bottom-aligned, uneven heights). Looks pre-existing; cosmetic.

### 💡 Out of scope
- Ordinals stripped in curb-pin card ("E 2 St", "1 Ave"): known, display formatter planned.
- Test suite not run per brief (CI covers `AXGoalDockTests` including the pinned `.large` dock height 232; visually the iPhone 17 Large dock matches main).

## Device-only / not verified
- Item 4 caveat: bubble placement when the camera recenters on the user after the overlay's first render (fresh install with permission prompt, late location fix).
- Item 1 acronym ("FDR Dr") on a real FDR block.
- Real-GPS behavior; simulator location only.

## Smoke tests run
- `gh pr view 156`: MERGEABLE/CLEAN; merged origin/main locally, clean.
- xcodebuild Debug simulator build: succeeded.
- iPhone 17: cold coach flow, AX3 relaunch, More medium and large, Settings Done and pushed-row back, curb-pin long-press and drag on E 2nd St.
- iPhone SE 3rd gen: XXXL and XXL dock screenshots.

## What's working
Four small changes landed exactly as described; the title-casing, detent, Done button and dot-avoidance all behave live, and the word-boundary tile title keeps "Overnight" intact on the tightest device/size combo.

## Cleanup
Constants.swift reverted, Config.xcconfig removed, SE device deleted, app uninstalled, both sims shut down, derived data deleted.
