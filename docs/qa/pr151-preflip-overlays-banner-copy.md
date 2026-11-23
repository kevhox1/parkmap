# PR #151 QA — pre-flip overlay dock clearance + banner copy split (#37 ① ②)

**Reviewed:** branch `fix/preflip-overlays-banner-copy` at `e3ddbc07`, against `docs/open-items.md` row 37, the 2026-11-22 addendum in `docs/design/goal-first-ambient-design.md`, `docs/qa/pr134*.md`, `docs/qa/pr133-dm2-goal-selector-ui.md` (pass-2 #4)
**Verdict: MERGE-WITH-FOLLOWUPS**

## Summary
Both fixes do what they claim. Live with `driveModeDefaultEnabled` flipped locally: at standard size the long-press card sits fully above the dock and clear of the rail; at AX3 and AX5 the 45% cap keeps the card fully on-screen with both buttons visible, and tapping Cancel at AX5 dismissed it (tappable, not swallowed by the dock). The helper is pure with sound fallbacks, the cap is flag-on only, the enum migration caught every call site, and `mapZStack` child count is unchanged. Residual items are non-blocking: the brief's premise about a changed banner gate is not borne out by the diff, the guide banner is effectively unreachable flag-on, and the sparse/stepped banners could not be triggered live.

## Acceptance criteria checklist
- [x] Flag-on, standard size: long-press card fully above dock, clear of the rail — **LIVE** (screenshot; card bottom edge above Start Driving, rail buttons end well above the card)
- [x] AX5 (`accessibility-extra-extra-extra-large`): card fully on-screen, Park here + Cancel visible — **LIVE**; Cancel tap dismissed the card — **LIVE**
- [x] AX3 (`accessibility-extra-large`): card fully on-screen, buttons visible — **LIVE** (see out-of-scope note)
- [x] Flag-off: overlays use legacy `browseSheetPeekHeight + 12` — **LIVE** (card sits just above the browse-sheet peek) + **CODE** (`guard goalDockVisible else { return legacy }`)
- [x] `ambientOverlayBottomPadding` pure, correct fallbacks — **CODE** (`nonisolated`, no state reads; unmeasured `.zero` frame gives `max(legacy, 12)` = legacy; cap skipped when containerHeight == 0)
- [x] 45% cap only flag-on — **CODE** (cap sits after the `goalDockVisible` early return; dock-visible input uses `AppConstants.driveModeDefaultEnabled`, false when flag off)
- [x] `.resolved(offsetDays:banner:)` migration complete — **CODE** (grep of app + tests: ContentView 2601, 3731, 7657; all DM2GoalSelectorTests sites; no `steppedDown:` label left)
- [x] `mapZStack` child count unchanged — **CODE** (diff only swaps the padding expression in three existing overlays)
- [x] Flag-off guards intact — **CODE** (guide-banner gate unchanged; no new flag-off-reachable path)
- [ ] `confirmPromptOverlay` live — NOT VERIFIED LIVE (finding #3); **CODE**: same one-line swap as the long-press overlay, which was live-verified
- [ ] Sparse / stepped-down banner copy live — NOT VERIFIED LIVE (finding #2); **CODE/tests**

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
None.

### 🟢 Minor / nit
- **#1: The brief's "banner gate changed / now has dock exclusion" is not in the diff, and the guide banner is unreachable flag-on**
  - Where: `ContentView.swift` `parkingGuideBannerOverlay` (~L3281)
  - What: the PR only changes the `.padding(.bottom, ...)` line. The gate `showParkingGuideBanner && !driveModeActive && !parkUntilMode && !blockSelectModeActive && curbPlacement == nil` is identical to `origin/main`. Flag-on, Overnight is pre-selected and sets `parkUntilMode = true`, so the banner is suppressed. Live: cleared `wepark_parking101_prompt_shown`, relaunched flag-on, no banner. The new dock clearance on this overlay is therefore dead code flag-on (harmless, correct if the gate opens). Pre-existing, not a regression.
  - Expected: nothing for this PR; add to the flip checklist (decide whether the Parking 101 prompt should show flag-on; relates to #37 ⑦).
  - Owner: `@ios-engineer`
- **#2: Sparse / stepped-down banners not reproduced live**
  - What: `simctl location set` moved the dot but the camera stayed on Madison Square Garden, so Park & Forget was only exercised in dense Midtown (selected, no banner = `banner: nil`, correct). By code/tests: `pickedIndex > 0` gives `.steppedDown`; else density below threshold gives `.sparse`; else nil. `bannerCopy`/`bannerIcon` match the locked addendum; tests cover all three plus copy/icon.
  - Recommend: one pan-to-sparse-area check in the flip smoke.
  - Owner: Kevin smoke / `@ios-engineer`
- **#3: `confirmPromptOverlay` not triggerable in the sim**
  - What: needs a delivered park-confirm notification response; not reproducible with AXe/simctl. Same one-line change and same helper input as the live-verified long-press card. High confidence, not 100%.

### 💡 Out of scope (logged, not fixed)
- AX3 as requested: the dock is ~68% of screen height; the card is capped at 45% so it overlaps the selected (Overnight) tile's lower half and sits just under Start Driving. Fully on-screen, both buttons visible.
- AX5: card overlaps Start Driving and the Overnight tile while open (accepted interim); the dock itself overflows (pre-existing, #37 ⑥).
- simctl names: AX3 = `accessibility-extra-large`, AX5 = `accessibility-extra-extra-extra-large`.
- Dock-height capture: `onboardingGoalDockFrame` via `.onGeometryChange` is `.zero` until first layout, which falls back to legacy (safe). On dock unmount the frame goes stale but `goalDockVisible` is false then. A one-frame lag on remount is possible; not observed.

## Smoke tests run
- `df -h /` before build: 8.6 GB free. One flags-on build into `~/Library/Caches/wepark-qa151-dd`, one incremental flags-off rebuild. Full suite not run (CI did).
- Flag-on rest, standard size: dock + rail render — **LIVE**, screenshot read.
- Long-press at standard / AX3 / AX5 flag-on — **LIVE**, screenshots read; Cancel tap at AX5 — **LIVE**.
- Guide banner flag-on — **LIVE** (not shown; #1).
- Park & Forget in Midtown — **LIVE** (no banner, correct).
- Flag-off rebuild + long-press — **LIVE** (legacy layout above browse-sheet peek). No main-branch build was made for a pixel diff (disk), so "byte-identical to main" rests on the CODE read of the legacy return path.
- Local flag flip reverted with `git checkout -- ios/WePark/WePark`; Config.xcconfig not committed; derived data deleted; simulator shut down.

## What's working
- Measured dock height instead of PR #134's hard-coded 326pt sum, so it holds at every Dynamic Type size.
- Pure helper with explicit fallbacks; the cap guarantees the card never leaves the screen.
- Exhaustive enum migration; `.steppedDown`/`.sparse` precedence is clean and copy/icon live in testable `nonisolated` properties.
