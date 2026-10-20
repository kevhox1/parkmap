# PR #134 QA — DM-2 Ambient Dock Layout Fix (dock-aware clearance + Start Driving backdrop)

**Reviewed:** branch `fix/dm2-ambient-dock-layout` at `fa1acab9`, against Kevin's live-smoke bug report (PR #134 description) and `docs/design/goal-first-ambient-design.md` §2.1–§2.4.
**Verdict:** 🟡 ship with caveats (MERGE — not blocking; two pre-existing gaps carried forward from PR #133 need a tracked follow-up before the flag ever flips on)

## Summary

This is a narrow, correctly-scoped fix for exactly the three bugs Kevin's live smoke caught on PR #133: the Report pill/"?" button overlapping the goal tiles, and "Start Driving"/toggle floating bare over the map. The flag-off path is byte-identical (verified by tracing both call sites' five inputs), the new pure function's worst-case math checks out against the dock's actual component heights, and the six new tests are real, meaningful assertions. The PR's own description is unusually honest about what it didn't fix: `confirmPromptOverlay` and `longPressParkConfirmOverlay` share the same stale-clearance pattern and are **not** structurally excluded from colliding with the dock — my own trace confirms this is a genuinely live, easily-reachable bug (not a hypothetical) once `driveModeDefaultEnabled` flips to `true`. That gap predates this PR (inherited from #133) and the flag stays `false`, so it doesn't block merging #134 itself, but it must not be allowed to go untracked.

## Acceptance criteria checklist (from PR #134's own dispatch)

- [x] Dock remains one cohesive bottom unit via `.safeAreaInset(edge: .bottom)` — verified by inspection; `GoalSelectorView.body` is a single `VStack`, unchanged structurally by this PR.
- [x] Report pill / "?" button offset above the dock when visible, via a testable pure function with tests — `communityMapChromeBottomPadding(goalDockVisible:browseSheetPeekHeight:)`, `ContentView.swift:5932`, wired at `ContentView.swift:2592`.
- [x] Toggle + Start Driving read as controls (material backdrops) — toggle already had `.regularMaterial` pre-PR (unmodified); Start Driving gets it added, `GoalSelectorView.swift:153`.
- [x] Flag-off / dock-hidden byte-identical — confirmed both algebraically (`guard goalDockVisible else { return browseSheetPeekHeight + 12 }`) and via `AppConstants.driveModeDefaultEnabled = false` short-circuiting `goalSelectorDockVisible` to `false` regardless of the other four inputs.
- [x] Guard tests for the new pure function — 6 tests in `DM2AmbientDockLayoutTests.swift`, all real assertions (see Smoke tests run).
- [ ] Full co-occurrence safety for every bottom-floating overlay sharing the old clearance pattern — **not achieved**, see Finding #1. Scoped out of this PR by its own dispatch, but flagging per my task brief: this is "a real still-live overlap, not a follow-up note."

## Findings

### 🔴 Blocking
None. The diff does what it claims, within its explicitly stated scope, and doesn't regress anything flag-off.

### 🟡 Significant

- **#1: `confirmPromptOverlay` and `longPressParkConfirmOverlay` can genuinely co-occur with the ambient dock once the flag flips — not just "theoretically," trivially**
  - Where: `ContentView.swift:2463` (`confirmPromptOverlay`), `ContentView.swift:2502` (`longPressParkConfirmOverlay`)
  - What: Both gates are `AppConstants.communityEnabled && <payload != nil> && !driveModeActive` — neither checks `parkUntilMode`, `activeSheet == nil`, or anything else that would exclude the ambient-rest state. `confirmPromptOverlay` in particular has **zero** dock-awareness: it fires off a push/local-notification-driven flow that can land at any time the user isn't in Drive Mode, which at ambient rest (flag on) is the *default* state. `longPressParkConfirmOverlay` fires on any long-press of the map at rest — again the literal common case once the flag is on. Both still use the stale `browseSheetPeekHeight + 12` clearance (~76pt with the frozen 64pt default peek height), which is exactly the clearance this PR just proved is wrong for the dock's real ~230–300pt height.
  - Expected: Either these two overlays get the same `goalDockVisible`-aware clearance treatment, or (if genuinely out of scope for this PR) a tracked ticket exists before `driveModeDefaultEnabled` is ever flipped to `true`, not just a paragraph in a PR description that will be forgotten.
  - Repro (once flag flips in a future build): flag on, cold launch (ambient dock visible, default goal selected) → trigger a "did it pass?" confirm-prompt notification (or just long-press the map) → the resulting card renders ~76pt above the screen bottom, landing on/inside the dock's tile row — the same visual bug this PR just fixed for the Report pill, reopened via a different trigger.
  - Owner: `@ios-engineer` (tracked follow-up before flag flip; does not block #134)

- **#2: Worst-case clearance constant doesn't account for Dynamic Type growth, and this isn't flagged anywhere**
  - Where: `communityMapChromeBottomPadding`, `ContentView.swift:5932-5942`
  - What: The 326pt sum is built entirely from `minHeight` constants (44/48/112) and a fixed 60pt banner estimate, all implicitly assuming roughly system-default font sizes. `GoalSelectorView`'s own header comment is explicit that every font in this screen is a semantic, Dynamic-Type-scalable style specifically so "a Large-Text accessibility user" isn't shut out — which means at larger accessibility text sizes, the toggle row's label, the Start Driving label, the tile text (2-line clamped, but at larger point sizes those 2 lines are taller), and the guard banner's wrapped text can all exceed their `minHeight` floors. The fixed 24pt "breathing room" buffer is the only cushion against that growth, and nothing in the code or PR description discusses whether it's sufficient at, say, `.accessibility3` or above.
  - Expected: Either confirm (by testing at a large Dynamic Type size) that 24pt of headroom is enough, or explicitly flag the limitation (e.g., "known not to hold at accessibility XL+ sizes, acceptable because X") the same way the PR explicitly flagged the full-palette-mode conservative overshoot and the `.regularMaterial` design-doc deviation.
  - Repro: Settings → Accessibility → Larger Text → max accessibility size, flag on, ambient rest with Park & Forget selected and the empty-map guard banner showing → compare Report pill position to dock top edge. Not verified by me — no simulator access from this sandbox; recommend Kevin add this to the Mac re-smoke pass.
  - Owner: `@ios-engineer`

### 🟢 Minor / nit

- **#3: `.regularMaterial` + `.bordered` layering on `startDrivingRow` — unverified cosmetic risk**
  - Where: `GoalSelectorView.swift:148-159`
  - What: `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))` is applied to the `Label` inside the button content, then `.buttonStyle(.bordered)` wraps that content with its own system-provided fill/border, then `.clipShape(RoundedRectangle(cornerRadius: 14))` clips the whole thing. `.bordered` on iOS does render its own translucent fill behind the label by default — stacking a second, inset `regularMaterial` rounded rect behind the label text (rather than behind the whole button) risks a visible "double rounded-rect" edge if `.bordered`'s default content insets don't line up with the frame this PR added. This is plausible-not-confirmed: I have no Xcode/simulator access in this sandbox to render and screenshot it (this repo's own live-UI-smoke gate for mount-chain PRs like this one — `ContentView.swift`/`.safeAreaInset` overlay code is explicitly in scope — could not be executed here; flagging explicitly per "no silent passes" rather than asserting it's fine).
  - Expected: Add "check Start Driving for a double-ring/layered look, not just legibility" to Kevin's re-smoke checklist (currently only asks "has a visible material backdrop" — true either way, double-layered or not).
  - Owner: `@ios-engineer` / Kevin's own Mac smoke (visual-only call)

- **#4: Re-smoke checklist doesn't explicitly cover the empty-map-guard banner case**
  - Where: PR #134 body, "Kevin's re-smoke checklist"
  - What: The 326pt worst-case clearance bakes in a 60pt guard-banner estimate (`EmptyMapGuardKind.steppedDown`/`.empty`, Park & Forget only), but the 7-item re-smoke checklist never asks Kevin to select Park & Forget in a state that actually triggers the banner. If that specific 60pt estimate were wrong, nothing in the checklist as written would catch it.
  - Expected: Add an 8th item: "Select Park & Forget somewhere the empty-map guard banner shows (stepped-down or true-empty) — confirm Report pill/"?" still clear the banner + tiles together."
  - Owner: `@ios-engineer` (one-line checklist addition)

### 💡 Out of scope (logged, not fixed)

- Full-palette-mode conservative overshoot (dock-visible clearance is sized for the worst case even when the tile row/banner are hidden in full-palette mode) — already flagged by the builder in the PR body as a known, accepted tradeoff for diff minimalism. Agree with that call; not re-litigating it here.

## Code-level verification detail

**Flag-off byte-identical, traced:**
- `communityMapChromeBottomPaddingValue` (`ContentView.swift:1076-1091`) calls `goalSelectorDockVisible` with `driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled, activeSheetIsNil: activeSheet == nil, driveModeActive: driveModeActive, blockSelectModeActive: blockSelectModeActive, spotPlacementActive: spotPlacementActive` — identical five named arguments, identical order, to `bottomSafeAreaContent`'s own `goalDockVisible` local at `ContentView.swift:2958-2964`. No drift between the two call sites.
- `AppConstants.driveModeDefaultEnabled = false` (`Services/Constants.swift:262`, unchanged by this PR) makes `goalSelectorDockVisible`'s leading `&&` operand `false`, short-circuiting the whole function to `false` regardless of the other four inputs — so `goalDockVisible` is `false` for every build configuration shipped today (drive-mode-active, full-palette, or otherwise).
- `communityMapChromeBottomPadding`'s `guard goalDockVisible else { return browseSheetPeekHeight + 12 }` returns the exact pre-PR expression — confirmed via `testCommunityMapChromeBottomPadding_dockHidden_matchesLegacySheetClearance`/`_tracksLivePeekHeight`.

**Worst-case constant math (326pt), checked against `GoalSelectorView.body`:**
`VStack(spacing: 10) { fullPaletteToggleRow; [EmptyMapGuardBanner]; startDrivingRow; [goalTileRow] }.padding(.bottom, 8)`.
- toggleRow: `.frame(minHeight: 44)` at `GoalSelectorView.swift:127` → 44, matches.
- startDrivingRow: `.frame(minHeight: 48)` at line 152 → 48, matches.
- goalTileRow (`GoalTile`): `.frame(minHeight: 112)` at line 238 → 112, matches.
- banner worst case 60pt: `EmptyMapGuardBanner` has `.padding(.vertical, 10)` (×2 = 20) plus up to two wrapped lines of `.subheadline` text (`.fixedSize(horizontal: false, vertical: true)`, no `lineLimit`) — ~40pt for two lines + 20pt padding ≈ 60pt is a reasonable estimate at standard text sizes, not padded generously beyond that (see Finding #2 for the Dynamic Type gap).
- inter-row gaps: `VStack(spacing: 10)`, worst case 4 rows present (toggle, banner, startDriving, tiles) → 3 gaps × 10 = 30, matches.
- dock's own bottom padding: `.padding(.bottom, 8)` at line 110 → 8, matches.
- Sum without breathing room: 44+60+48+112+30+8 = 302, matches the PR's own stated "dock's full worst-case height ... = 302" and the `testCommunityMapChromeBottomPadding_dockVisible_clearsFullDockHeightWithBreathingRoom` test's literal `302` constant.
- +24pt breathing room → 326, matches the shipped constant and `testCommunityMapChromeBottomPadding_dockVisible_returnsFixedWorstCaseClearance`'s expected `326`.
Math is internally consistent and matches the live view's actual layout constants at standard Dynamic Type. Margin over the true worst case is thin (24pt) and not stress-tested against accessibility text sizes (Finding #2).

**Six compile-failure-class scan:**
1. Contextual-type-on-literal-receiver — N/A, no literal-receiver calls added.
2. Labeled-argument order — both new call sites (`goalSelectorDockVisible(...)`, `communityMapChromeBottomPadding(...)`) match their declarations' argument order exactly.
3. Memberwise-init argument order — N/A, no new struct inits.
4. XCTestCase-extension name shadowing — N/A, `DM2AmbientDockLayoutTests` is a single `final class`, no extensions, no name collisions with other test files' helpers.
5. MainActor default isolation — `communityMapChromeBottomPadding` is declared as a plain top-level `func` (not `nonisolated`), same as its own cited precedents `recenterPillBottomPadding` and `paddingForBannerState` (also plain `func`, not `nonisolated`, both already exercised synchronously from plain `XCTestCase` methods in `W85cPolishTests.swift` today). This is consistent with existing, already-compiling-and-passing precedent in this file, not a new risk — the functions this PR mirrors for isolation treatment are the correct ones to mirror.
6. ObjC-runtime name collision — N/A, no bare `Category`/`Protocol`/`Method`/`Ivar` identifiers introduced.

**Smallest-diff discipline / scope guard:**
- Files touched: `ContentView.swift`, `Views/GoalSelectorView.swift`, new `WeParkTests/DM2AmbientDockLayoutTests.swift`. No touch of `MapViewRepresentable.swift`, anything under `Services/`, or `ParkUntilSheet`.
- `driveModeActive` appears exactly once in the diff, as a read (`driveModeActive: driveModeActive` passed into the new call site) — not modified.
- `AppConstants.driveModeDefaultEnabled` remains `false` in `Services/Constants.swift` (untouched by this PR's diff).

**`.regularMaterial` deviation against design doc §2.3:**
Design doc §2.3 (`docs/design/goal-first-ambient-design.md:121-127`) specifies `.buttonStyle(.bordered)` alone for Start Driving, with no material background — the PR's claim about the literal spec text is accurate. Notably, §2.4 (full-palette toggle, same doc, lines 136-139) states the *general* principle this app already applies everywhere else: "every other floating control in this app... uses a material background over the map... a live map underneath has unpredictable color/contrast, and naked text would be the first legibility bug of its kind in this codebase." The PR's fix is a direct, correctly-flagged application of that same already-stated principle to the one row the literal §2.3 text missed — not an improvised deviation. Reasonable.

## Smoke tests run

- Read full diff (`git diff main...fa1acab9`) for both source files and the new test file.
- Traced both call sites of `goalSelectorDockVisible` to confirm identical five-input wiring — no drift.
- Verified `AppConstants.driveModeDefaultEnabled = false` is still committed in `Services/Constants.swift` (flag off).
- Derived the dock's real worst-case height from `GoalSelectorView.swift`'s actual `.frame(minHeight:)`/`.padding()` values and cross-checked against the new function's hardcoded constants — matches (302 + 24 breathing room = 326).
- Read `EndDrivePillZOrderTests`/`RecenterPillBottomPaddingTests` in `W85cPolishTests.swift` to confirm `communityMapChromeBottomPadding`'s lack of `nonisolated` mirrors already-working precedent, not a new risk.
- Traced `confirmPromptOverlay`/`longPressParkConfirmOverlay`/`parkingGuideBannerOverlay`'s visibility gates against `goalSelectorDockVisible`'s exclusion list to determine real (not just theoretical) co-occurrence risk with the ambient dock — found `confirmPromptOverlay`/`longPressParkConfirmOverlay` genuinely unguarded (Finding #1); `parkingGuideBannerOverlay` is guarded by `!parkUntilMode`, which is `true` at ambient rest with a goal selected except when the user has toggled to full-palette mode (`toggleFullPaletteMode()` → `clearParkUntilFilter()` sets `parkUntilMode = false`), so it's a narrower but still real overlap window.
- Read the design doc §2.3/§2.4 to verify the `.regularMaterial` deviation claim against the literal spec text.
- Reviewed all 6 new tests in `DM2AmbientDockLayoutTests.swift` — all assert real, specific numeric/boolean outcomes against the pure function; no vacuous/no-op assertions.
- **Not run:** live build + simulator smoke. No `xcodebuild`/`xcrun`/Xcode toolchain available in this sandbox (Linux VPS, confirmed via `which xcrun` → not found). This PR touches `ContentView.swift` overlay/safeAreaInset code, which per this repo's merge-gate discipline should get a live-UI screenshot smoke before ship — that step is **not verified by me** and must come from Kevin's own Mac re-smoke (the PR body's 7-item checklist, plus Findings #2–#4's suggested additions).

## What's working

- The core fix is exactly the right shape for the bug: extracting a pure, testable function instead of reaching for `GeometryReader` at runtime (explicitly, correctly, citing the W8.5c-polish revert precedent for why that's the wrong tool here).
- Threading the SAME five inputs through both call sites via named arguments (rather than, say, a shared private stored property that could silently drift) is a good structural choice — a future edit to `goalSelectorDockVisible`'s signature would force both call sites to update together or fail to compile.
- The PR description's own "Out of scope, flagging as a possible follow-up" section is honest about exactly the gap I independently found (Finding #1) — this is the kind of self-disclosure that makes a narrow-scope PR safe to merge even with known limitations, as long as the disclosed gap actually gets tracked rather than lost.
- Test coverage of the pure function is tight and well-targeted: it specifically guards the regression shape (dock-visible must exceed dock-hidden for the same peek height) rather than just asserting magic numbers in isolation.
