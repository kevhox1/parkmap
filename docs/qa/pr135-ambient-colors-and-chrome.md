# Ambient Colors + Chrome Restructure QA Pass 1 — 2026-10-21

**Reviewed:** branch `fix/ambient-colors-and-chrome` at `400dcb60`, against `docs/design/goal-first-ambient-design.md` Addendum 2 (Parts B/C) and `docs/drive-mode-default-spec.md` §0.8 (Part A context).
**Verdict:** 🟡 FIX-THEN-MERGE — no blocking logic defects found by static/adversarial read, but (1) the PR's own mandatory Mac build + live-UI smoke has not been run by anyone yet (builder disclosed this; I have no Xcode/simulator in this sandbox either, so I could not run it), and (2) two real, non-cosmetic findings below should be triaged — one acknowledged/fixed, one watched during the live smoke — before this ships. This PR touches `ContentView.swift` + `.safeAreaInset` overlay-attachment code, which makes live-UI smoke merge-blocking per this repo's own gate, not optional polish.

## Summary

This is a well-reasoned, narrowly-scoped bundle fix. All three parts (ambient-colors bug, chrome restructure, goal-identity pill) trace cleanly to their stated root causes, the flag-off byte-identical claims hold up under direct diff comparison against `main`, and the new pure functions are properly `nonisolated static` and unit-tested. I found no 🔴 blocking defects. I did find two 🟡s worth attention: a flag-independent performance cost newly introduced into Drive Mode's continuous camera-follow loop (worth a live jank check, not necessarily a code fix), and a real — if narrow — gap in the PR's own "provably correct, no other code path" claim for `activeGoalForParkUntilPill` (the arrival-confirm "Park Here" flow can open the power-user `ParkUntilSheet` while flag-on in goal-first mode, producing a misleading toast even though the pill itself still self-heals to the correct goal state on the next rebuild). Neither invalidates the PR's core approach; both are concrete, reproducible-by-trace findings, not vibes.

## Acceptance criteria checklist

### Part A — ambient curb-colors bug
- [x] `dismissLocationPrimingCard(allowed: true)` sets `recenterOnUserAtLaunch = true` before `requestAndFetchLocation()` — verified by direct read (`ContentView.swift:3750-3751`); also verified the card can never show flag-off (`locationPrimingCardShouldShow` ANDs `driveModeDefaultEnabled`), so this new write is unreachable flag-off — zero misfire risk.
- [x] Flag-gated launch-default `region` — flag-off byte-identical to the old literal span, verified by diffing `ContentView.initialLaunchRegion(driveModeDefaultEnabled: false)` against `main:ContentView.swift:448-454` (same `0.07/0.05` span, same `manhattanCenter`). Flag-on span (~400m, `AppConstants.streetLevelRecenterMeters`) computes to ≈0.0036°lat/0.0048°lng at `manhattanCenter`'s latitude — comfortably inside `polylineHideSpanThreshold` (0.04°) even after the diagnosis's cited 1.4–1.6× MapKit aspect-fit inflation (0.0048×1.6 ≈ 0.0077°, still ~5× under threshold). Margin is real, not just-barely-passing.
- [x] `handleRegionChanged` calls `rebuildOverlays(at: lastEvaluatedAt)` directly, flag-independent — verified. See 🟡 Significant #1 for a performance concern on this specific change.
- [x] DM-2 goal-recompute block moved above the zoom-threshold guard — verified correct ordering; `parkUntilMode`/`parkUntilTarget`/`parkAndForgetGuardState` now evaluate on every `rebuildOverlays` call regardless of zoom, guard now only gates the rendered payload. Confirmed the block is a no-op in both positions when the flag is off (`AppConstants.driveModeDefaultEnabled` gate), so flag-off is byte-identical as claimed.

### Part B — chrome restructure
- [x] "?" joins `recenterButtonStack` as its last circle, flag-on only — verified (`ContentView.swift`, new `if AppConstants.driveModeDefaultEnabled` block after button 4). Flag-off `mapKeyButton` in `communityMapChromeOverlay` is untouched in this diff (no lines around it changed).
- [x] Report pill moves into `GoalSelectorView`'s own top row, flag-on only — verified; `GoalSelectorView` only mounts when `goalSelectorDockVisible(...)` is true, which itself ANDs `driveModeDefaultEnabled`, so Report never leaves `communityMapChromeOverlay` flag-off.
- [x] `communityMapChromeOverlay` suppresses both pieces via `&& !goalSelectorDockVisible(...)` reusing the exact 5-input function `bottomSafeAreaContent`'s own `goalDockVisible` local computes — verified same call shape, no second boolean invented, no redundant separate `driveModeDefaultEnabled` check (already embedded in `goalSelectorDockVisible`).
- [x] `communityMapChromeBottomPadding` reverted to its pre-#134 shape — verified against the pre-#134 commit (`0b0f7d5c`): that commit had **no such named function at all** — the clearance was an inline `browseSheetPeekHeight + 12` at each call site. PR #134 extracted + dock-branched it; this PR's revert collapses it back to a single-branch named function returning the mathematically identical `browseSheetPeekHeight + 12`. Behaviorally exact; structurally now a named (testable) function instead of inline literals, which the PR discloses and is a reasonable, non-regressive choice.
- [x] Full-palette mode — verified `GoalSelectorView.body`'s `topRow` (Report + toggle) always renders regardless of `fullPaletteMode`; only `goalTileRow` is conditionally hidden. So in full-palette mode the Report pill correctly rides the now-shorter dock height with no stranded floating chrome — confirmed by code read, not yet confirmed visually (no simulator in this sandbox).

### Part C — goal pill
- [x] `GoalParkUntilPill` renders in the `ParkUntilPill` slot when the live filter came from a goal tap — verified call site (`bottomSafeAreaContent`, `if let activeGoal { GoalParkUntilPill(...) } else { ParkUntilPill(...) }`), mutually exclusive, no double-render in any state I could construct.
- [x] Falls back to today's generic `ParkUntilPill`, byte-identical, for full-palette/flag-off — verified identical `ParkUntilPill(targetDate: target) { clearParkUntilFilter() }` call, matching `main`'s call site exactly.
- [x] Same ✕-clear semantics, no new confirm, in both variants — verified, both wire straight to `clearParkUntilFilter()`.
- [x] Compass: no change — verified no diff touches `MapViewRepresentable.swift`'s compass code. Note: Addendum 2 §A2.3 asked for an *investigation* ("verify which of the two PR #132 actually did") before concluding "not a regression" — this PR's body states the conclusion but the investigation itself isn't evidenced in the diff. Logged as 💡 out of scope below, not blocking.
- [x] `activeGoalForParkUntilPill`'s zero-stored-state derivation — the core claim ("rebuildOverlays unconditionally recomputes on every call, so `selectedGoal` is always fresh when this reads non-nil") holds for every entry point gated by `parkUntilClockButtonVisible`. It does **not** hold for one additional reachable entry point the PR's own doc comment doesn't account for — see 🟡 Significant #2. The practical outcome (the pill itself) still self-heals correctly; the claim "no other code path could have set a non-goal target while this reads non-nil" is the part that's actually false, and the toast UX is what leaks the gap.
- [x] Midnight-boundary / ambiguous-target scenarios — adversarially checked the specific scenario the dispatch named (power-user picks a time that numerically coincides with a goal's formula): `activeGoalForParkUntilPill` ignores `parkUntilTarget`'s *value* entirely — it's a pure function of `(selectedGoal, driveModeDefaultEnabled, fullPaletteMode)`. Since `parkUntilClockButtonVisible` hides the sheet's normal entry point whenever this function could return non-nil, that specific coincidental-target scenario is structurally impossible through the normal entry point — confirmed, not just asserted.

## Findings

### 🔴 Blocking
None found.

### 🟡 Significant

- **#1: `handleRegionChanged`'s new `rebuildOverlays(at:)` call adds a continuous, flag-independent cost to Drive Mode's 1Hz camera-follow loop, not yet live-profiled.**
  - Where: `ContentView.swift`, `handleRegionChanged(_:)` (new `rebuildOverlays(at: lastEvaluatedAt)` line); interacts with `MapViewRepresentable.swift`'s per-tick `setDriveCamera` (`coordinatorActions.setDriveCamera`, called from `handleLocationUpdate()` at ~1Hz GPS during Drive Mode).
  - What: Every `setCamera(animated: true)` call fires one `regionDidChangeAnimated` → async `onRegionChanged` → `handleRegionChanged`. During Drive Mode this happens roughly once per second for the entire drive (`driveModeCameraSpan = 0.003°`, well under `polylineHideSpanThreshold`, so the full classification loop — not the cheap zoomed-out early-return — runs every tick). This is in addition to `tileLoader.loadTiles(forRegion:)`'s own pre-existing, unconditional `rebuildSegments(forKeys:)` call at the same cadence (confirmed: `rebuildSegments` always reassigns `segments = flat` even on a cache hit, every call, flag-independent, pre-existing). So this PR roughly doubles the per-tick main-thread cost during the single highest-stakes interaction (active driving), rather than introducing a new order of magnitude — the PR's own doc comment's "not a new order of magnitude" framing is directionally correct, but "it's only 2x, not 10x" is not the same claim as "no perceptible cost," and this is a case where even small per-frame hitches matter (driving UX, not browsing).
  - Expected: Per the repo's own live-UI-smoke-is-merge-blocking rule for mount-chain PRs, a change to the Drive Mode camera-update hot path should be smoke-verified for jank, not shipped on code-inspection confidence alone.
  - Repro: Flag on locally, "Start Driving" (Cruise), drive/simulate a continuous ~60s route through a dense loaded-tile area (500–2000 segments), watch for dropped frames in the polyline repaint or camera animation stutter. Not yet run — no simulator in this sandbox.
  - Owner: `@ios-engineer` (verify via Kevin's Mac smoke first; only write a debounce/early-equal-check fix if the smoke actually shows jank — don't speculatively optimize an unconfirmed cost).

- **#2: `activeGoalForParkUntilPill`'s "no other code path" claim is incomplete — the W8.5d arrival-confirm "Park Here" flow can open `ParkUntilSheet` while flag-on + goal-first mode, producing a misleading toast.**
  - Where: `ContentView.swift` — the doc comment above `activeGoalForParkUntilPill` (new in this PR, ~line 2177) states "The power-user `ParkUntilSheet` clock icon is unreachable in that same state (`parkUntilClockButtonVisible`), so there is no other code path that could have set a non-goal target while this reads non-nil." The counter-example: `ArrivalPromptSheet`'s `onParkHere` closure (pre-existing, untouched by this PR, ~line 1736) sets `activeSheet = .parkUntil` directly, with no `fullPaletteMode`/flag gate at all.
  - What: `ArrivalPromptSheet` only fires for **destination-mode** Drive (`driveModeStyle = .destination`, entered via the Search icon → `BrowseSearchAreaView.handleGoTap()` → `onRouteReady`), which is reachable regardless of the flag and regardless of goal-first/full-palette mode (the Search icon in `recenterButtonStack` is never gated by `driveModeDefaultEnabled` — only the clock icon is). `finalApproachState` explicitly stays `.outside` for Cruise sessions (confirmed at `ContentView.swift:3810`), so this specific path does **not** fire from the goal-first dock's own "Start Driving" button — but it does fire from the coexisting destination-mode Drive flow, which a flag-on user in goal-first mode can still reach via Search. On arrival + "Park Here": `endDriveMode()` runs, then `activeSheet = .parkUntil` opens `ParkUntilSheet` directly — bypassing `parkUntilClockButtonVisible`'s gate and the design doc's explicit "not reachable directly from the goal-first home screen" invariant (§0.8.9, Addendum 2 A2.2's own premise). If the user then picks a custom time, `ParkUntilSheet`'s `onConfirm` sets `parkUntilTarget`/`parkUntilMode`, fires a toast ("Showing blocks free until `<custom time>`"), **then calls `rebuildOverlays(at: .nowET)` in the same closure** — which (since flag-on && `!fullPaletteMode` still holds) immediately overwrites `parkUntilTarget` back to the goal's own computed value, in the same synchronous call. Net effect: the toast is wrong (claims the custom time took effect), but the pill/map correctly show the goal's state — so the *displayed* filter state is never actually incorrect, only the toast is. This also means `ParkUntilSheet` genuinely is reachable in this state, not "structurally unreachable" as both the design doc and this PR's new comment assert.
  - Expected: Either the design doc's "not reachable" invariant should hold for all entry points (gate `onParkHere`'s `activeSheet = .parkUntil` too), or the doc comment's claim should be corrected to acknowledge this gap, and the misleading toast should be suppressed/corrected when the goal-recompute block is about to immediately override the just-set value.
  - Repro (traced, not live-run): Flag on locally → stay in goal-first mode (don't toggle full-palette) → use the Search icon to route to a destination → arrive → tap "Park Here" → `ParkUntilSheet` presents → pick any time → confirm → observe the toast claims the picked time, but the `ParkUntilPill`/`GoalParkUntilPill` slot reads the goal's own target instead.
  - Owner: `@ios-engineer` — low-risk fix (gate `onParkHere`'s sheet open the same way the clock icon is gated, or skip the toast when the immediately-following `rebuildOverlays` is about to override it). Not a merge-blocker on its own — the user-visible map/pill state is never wrong, only a toast message — but it directly contradicts a claim this PR's own code comments make, so worth a decision (fix now vs. explicitly deferred) rather than silently carrying an inaccurate comment forward.

### 🟢 Minor / nit
- `AmbientColorsAndChromeFixTests.swift` and `DM2AmbientDockLayoutTests.swift` are marked `[COMPILE-UNVERIFIED]` per the repo's VPS/Mac split convention — expected, not a defect, flagging only so it's visible in this report that neither I nor the builder has run `xcodebuild test` on this branch yet.
- `GoalParkUntilPill`'s "never render 'Good through Today'" defensive floor duplicates (rather than calls) `goalGoodThroughLabel(for:)`'s identical guard — the PR's own doc comment discloses this as intentional (different input shapes: segment vs. resolved target), so not flagging as a real duplication risk, just noting the pattern for future maintainers.

### 💡 Out of scope (logged, not fixed)
- Addendum 2 §A2.3's compass investigation ("verify which of the two PR #132 actually did: `showsCompass = false` globally, or a custom-positioned `.adaptive` button left untouched") was not performed in this PR — the PR body concludes "not a regression" without showing the trace. For the record: I checked `MapViewRepresentable.swift` and found **both** — `mapView.showsCompass = false` (global system compass off) *and* a separately-added custom `MKCompassButton` with `.compassVisibility = .adaptive`, explicitly hidden during Drive Mode (`compassButton?.isHidden = parent.driveModeActive`) but not fully audited here for every rotation state. This matches Addendum 2's second (non-regression) scenario closely enough that I agree with the PR's conclusion, but the investigation itself is still worth a follow-up note in the design doc rather than a bare assertion, since this PR's diff doesn't touch that file at all.

## Smoke tests run

- Static diff review of all 4 changed files (`ContentView.swift`, `Constants.swift`, `GoalSelectorView.swift`, both test files) against `main` and against the PR's own 13-item acceptance checklist.
- Byte-identical flag-off verification for `initialLaunchRegion` (direct diff against `main:ContentView.swift:448-454`) and `communityMapChromeBottomPadding` (direct diff against pre-#134 commit `0b0f7d5c`).
- Numeric verification of the flag-on launch span against `polylineHideSpanThreshold` including the diagnosed MapKit aspect-fit inflation margin, and against `TileLoader.tileKeys`'s grid math (new span: ~6×7 candidate cells, well under the 200-tile LRU cap; old span: ~35×26 candidate cells, consistent with the "hundreds of keys" diagnosis) — confirms Part A fix 5's LRU-flood claim.
- Traced `regionDidChangeAnimated`'s firing cadence (once per settled gesture/animation, confirmed via `MapViewRepresentable.swift`'s own doc comments and the async-dispatch pattern) and Drive Mode's per-tick `setCamera` call to confirm the #31-class regression guard holds (no synchronous state mutation inside `updateUIView`) and to surface finding #1 above.
- Traced every `ParkUntilSheet`/`.parkUntil` entry point in `ContentView.swift` to adversarially test the `activeGoalForParkUntilPill` "provably correct" claim — found finding #2 above.
- Confirmed no `Calendar.current` anywhere in the diff; confirmed `driveModeDefaultEnabled` is still `false` committed; confirmed `driveModeActive` is untouched by this diff; confirmed the diff is scoped to the 5 files the PR describes (no stray edits).
- Compile-failure-class scan (all 6 known classes): no literal-receiver ambiguity introduced; labeled-argument order matches declarations at every new call site (`GoalSelectorView.init`, `goalPillContent`, `activeGoalForParkUntilPill`, `GoalParkUntilPill`'s memberwise init); no XCTestCase-extension name collisions (new helper `et(...)` is `private` to its class); all new pure functions intended for sync-XCTest use are `nonisolated static`/`nonisolated`; no ObjC-runtime name collisions.
- **Not run — no Xcode/simulator in this sandbox (Linux VPS):** the PR's own `xcodebuild ... build test` command, and all 8 steps of the live-UI smoke script. This is the gap that keeps this from an unqualified "ship it" — per this repo's rule, mount-chain PRs need a live screenshot/visual check, not test-suite confidence alone, and that hasn't happened from either side yet.

### Smoke script — additions for Kevin's re-smoke (steps 9–11 added to the PR's existing 8)

9. **(Flag on, destination-mode Drive, not Cruise)** Stay in goal-first mode (don't toggle full-palette) → tap the Search icon (not "Start Driving") → route to any destination → arrive → tap "Park Here." Confirm whether `ParkUntilSheet` appears at all (per finding #2, it should — this is the exact gap). If it does, pick a time and confirm: does the toast ("Showing blocks free until X") match what the `ParkUntilPill`/`GoalParkUntilPill` slot actually shows afterward, or do they disagree?
10. **(Flag on, Cruise, performance)** "Start Driving," let the follow camera run continuously through a dense, fully-tile-loaded area for 30–60 seconds (simulate GPS movement if on sim). Watch specifically for dropped frames/stutter in the polyline repaint or camera motion — this exercises finding #1's new per-tick `rebuildOverlays` cost.
11. **(Flag off)** Repeat step 3 of the original script (pinch zoomed out past the hide threshold, then back to street level) with the flag **off**. Part A fix 3 is flag-independent, so the stale-repaint bug it fixes should also be fixed flag-off — confirm the benefit, not just the flag-on case the original script covers.

## What's working

- The flag-off byte-identical discipline is genuinely well-executed throughout — every new gate traces back to a boolean that's provably `false`-by-construction when the flag is off (`goalSelectorDockVisible`, `locationPrimingCardShouldShow`, `activeGoalForParkUntilPill`), not just "probably fine."
- The LRU-flood and overlay-hide-threshold math in Part A fix 2 is correct with real margin, not a just-barely-passing number — I ran the actual grid-cell arithmetic against `TileLoader`'s real `rowSize`/`colSize` constants rather than taking the doc comment's claim at face value, and it holds.
- Part B's "give it a permanent home instead of a clearance constant" approach is the right structural fix for the bug class PR #134 only patched — Report pill and "?" now genuinely can't desync from the dock's height again, confirmed by reading how `topRow` sits inside the same `VStack` SwiftUI already lays out top-to-bottom.
- Part C's formatter reuse is clean — `goalPillContent` calls the real `ParkingGoals.relativeDayLabel`/`ParkUntilSheet.formatTime` rather than reinventing date math, and the "never render 'Good through Today'" defensive floor is consistent with the existing per-segment formatter's own guard.
- Deviations from the dispatch (separate `GoalParkUntilPill` view instead of a `ParkUntilPill` parameter; zero-new-state `activeGoalForParkUntilPill`) are disclosed explicitly in the PR body rather than silently substituted — exactly the behavior this repo's process expects from a builder agent.

---

# Pass 2 addendum — 2026-10-21

**Reviewed:** branch `fix/ambient-colors-and-chrome` at `61ed8e11` (diff from Pass 1's `874b814e`, builder fix commit `61ed8e11`).
**Verdict:** ✅ MERGE — both Pass 1 🟡s are correctly resolved and verified by trace + new tests. No new defects introduced. The only remaining gate is the mandatory Mac build + live-UI smoke (unchanged process requirement from Pass 1, not a new code concern) — once that passes, this is ready.

## Diff-scope check

`git diff 874b814e..61ed8e11 --stat`: exactly 2 files (`ContentView.swift`, `AmbientColorsAndChromeFixTests.swift`), 255 insertions / 17 deletions. Confirmed nothing else drifted — no changes to `Constants.swift`, `GoalSelectorView.swift`, or `DM2AmbientDockLayoutTests.swift`. Scope matches exactly what the commit message claims: the two 🟡 fixes, their tests, and the `activeGoalForParkUntilPill` doc-comment update. No `Calendar.current` introduced.

## 🟡 #1 (Drive Mode per-tick rebuild cost) — re-verified, resolved correctly

New `ContentView.shouldRebuildOverlaysOnRegionChange(driveModeActive:) -> Bool { !driveModeActive }` gates only the one line added in Pass 1 (`rebuildOverlays(at: lastEvaluatedAt)` inside `handleRegionChanged`). Traced every other `rebuildOverlays` trigger to confirm none of them were touched by this gate:

- `handleSegmentsChanged()` (`.onChange(of: tileLoader.segments.count)`) — completely untouched, unconditional, fires regardless of `driveModeActive`. This is Drive Mode's real pre-existing repaint mechanism as new tiles stream in while driving — confirmed still live.
- `handleTimerTick()` (60s timer) — untouched, unconditional. Still the self-correcting backstop in every state.
- `handleSelectionChanged()` — untouched, unconditional.
- `tileLoader.loadTiles(forRegion:)` inside `handleRegionChanged` — untouched, still called every region change regardless of the new gate (only the `rebuildOverlays` call is conditional, not `loadTiles`).

So the gate removes exactly the one thing it claims to remove (the new per-tick path from Drive Mode's own `setDriveCamera` → `regionDidChangeAnimated` loop) and nothing else. Confirmed the browse-mode staleness fix (the actual bug Part A fix 3 targets) stays fully intact in both flag states, since `shouldRebuildOverlaysOnRegionChange` reads only `driveModeActive`, never the flag — browse mode (where `driveModeActive` is always `false`) gets the unconditional repaint in every case, flag on or off, exactly as before this fix.

**One edge case I traced that's worth naming explicitly (not a new regression, a disclosed trade-off):** a user who manually pinches zoom during Drive Mode's `followPaused` state (FT-17 — panning/pinching pauses the custom follow camera but does not exit Drive Mode, so `driveModeActive` stays `true`) now gets the *same* gated-off behavior as the per-tick camera path, since the gate can't distinguish "genuine user pinch while driving" from "automatic per-tick follow camera" — both just read `driveModeActive == true`. If that pinch happens to zoom out past the hide threshold and back to an already-fully-loaded area (no net `segments.count` change), the overlay would stay stale until the 60s timer self-corrects it — i.e., Drive Mode's pinch-while-paused interaction reverts to exactly the *pre-Part-A-fix-3* staleness window, not a new one. Since the fix's own stated intent is "restores Drive Mode's prior repaint economics exactly," this is consistent with that intent, not an oversight — flagging only so it's on record, not as a blocker.

Tests (`testDriveModeActive_doesNotRebuild`, `testDriveModeInactive_rebuilds`) correctly pin the binary gate behavior; both pass by inspection (trivial pure-boolean function, no edge cases to miss).

## 🟡 #2 (misleading toast) — re-verified, resolved correctly; one adversarial case talked through

New `ContentView.parkUntilConfirmToastMessage(activeGoal:pickedTargetDate:resolvedTarget:now:)`:
```swift
guard let activeGoal else {
    return "Showing blocks free until \(ParkUntilSheet.formatTime(pickedTargetDate))"
}
let content = goalPillContent(for: activeGoal, target: resolvedTarget, now: now)
return "Showing \(content.shortName) blocks — \(content.trailingClause)"
```

**Byte-identical legacy string, verified char-for-char:** the pre-fix line was `ToastService.shared.show(message: "Showing blocks free until \(timeStr)")` where `timeStr = ParkUntilSheet.formatTime(targetDate)`, and the call site passes `pickedTargetDate: targetDate`. `"Showing blocks free until \(ParkUntilSheet.formatTime(pickedTargetDate))"` reduces to the identical literal — same leading text, same spacing, same trailing interpolation — for every call where `activeGoal == nil`. Confirmed identical by direct string comparison, not just "looks the same."

**The adversarial question — does the goal-branch copy make sense when the user picks a custom time while a goal is active? Is it honest?** Traced the call-site ordering: `rebuildOverlays(at: .nowET)` runs as its own synchronous statement *before* `resolvedTarget: parkUntilTarget ?? targetDate` is evaluated, so by the time the toast is built, `parkUntilTarget` already reflects whatever the DM-2 recompute block (unconditional whenever `driveModeDefaultEnabled && !fullPaletteMode`) just silently overwrote it to — i.e., `resolvedTarget` is genuinely "what's now live," not a stale read. So: **yes, the toast is now honest** — it describes the state that's actually showing on the map/pill, which is exactly what QA Pass 1's finding asked for (the bug was that the old toast described the user's *input*, which never took effect). This is a correct and sufficient fix for the finding as filed.

What it does *not* do — and I want to be precise that this is a UX-quality observation, not a reopened correctness bug — is explain to the user *why* their custom pick was overridden. A user who explicitly opens `ParkUntilSheet` (via the pre-existing `ArrivalPromptSheet.onParkHere` auto-fire, the one reachable path in this state), picks e.g. 3:00 PM, taps Confirm, and sees "Showing Overnight blocks — Good through tomorrow" will reasonably wonder why their 3:00 PM pick is nowhere in the toast. That confusion is real, but it is a *different* problem than the one Pass 1 filed (dishonesty) — the builder's own commit message is explicit that gating `onParkHere`'s reachability was the alternative, larger-diff fix they chose not to take, and that choice is disclosed, not silent. I'm logging the residual "confusing but true" gap as 🟢 below rather than reopening 🟡 #2, since the specific defect I filed (the toast asserting something false) is fully closed.

Tests (`testNoActiveGoal_rendersLegacyToastText_byteIdentical`, `testNoActiveGoal_ignoresResolvedTarget`, `testActiveGoal_ignoresPickedTargetDate_usesResolvedTargetViaGoalPillContent`, `testActiveGoal_allThreeGoals_composeCorrectly`) correctly cover the byte-identical legacy path, the "never reads `resolvedTarget` when no goal" guard, the core "describes what's live, not what was picked" fix, and all three goals' icon/short-name composition. `testActiveGoal_ignoresPickedTargetDate_usesResolvedTargetViaGoalPillContent`'s explicit `XCTAssertFalse(message.contains(...))` assertion that the picked time string never appears in the goal-branch toast is a good regression guard for exactly the bug that was filed.

## Doc comment completion

`activeGoalForParkUntilPill`'s doc comment now names `ArrivalPromptSheet.onParkHere` explicitly as the known third entry point and correctly distinguishes "the function's state-correctness claim still holds" (true — `parkUntilTarget`'s *value* can never diverge from the goal's by the time anything reads it) from "there is no other code path" (which Pass 1 showed was false, and this revision no longer claims). Accurate, not overclaiming.

## Compile-failure-class scan (fix diff only)

1. Contextual-type-on-literal-receiver — none introduced.
2. Labeled-argument order — `parkUntilConfirmToastMessage(activeGoal:pickedTargetDate:resolvedTarget:now:)`'s declaration order matches its one call site (`onConfirm`) and all 4 new test call sites exactly, argument-by-argument. `shouldRebuildOverlaysOnRegionChange(driveModeActive:)` is single-argument, no ordering risk.
3. Memberwise-init argument order — no new structs in this diff, N/A.
4. XCTestCase-extension name shadowing — `ParkUntilConfirmToastMessageTests` defines its own `private func et(...)`, duplicating the name already used privately inside `GoalParkUntilPillContentTests` earlier in the same file. Both are `private` to their own class (not `XCTestCase` extensions), so this is not the failure class in question — no collision, confirmed by Swift's type-scoped (not file-scoped) `private` semantics.
5. MainActor default isolation — both new functions are `nonisolated static func`; `parkUntilConfirmToastMessage` calls the also-`nonisolated static` `goalPillContent` internally (bare name, same type — resolves fine without a `Self.`/`ContentView.` prefix). No isolation mismatch for the sync-XCTest call sites.
6. ObjC-runtime name collision — no `Category`/`Protocol`/`Method`/`Ivar` touched.

Clean.

## 🟢 Minor (new, Pass 2)

- **Residual UX gap, not a defect:** per the adversarial toast trace above, a user who reaches `ParkUntilSheet` via the `onParkHere` auto-fire while a goal is active and picks a custom time gets an honest-but-unexplained toast (names the active goal, not their pick, with no stated reason). Worth a follow-up design decision (either suppress/relabel the sheet's own Confirm button in that state, or add a one-line "a goal is already active" sub-text to the sheet itself) — not blocking this PR, since the filed defect (false toast) is fixed, and the builder's own commit message already discloses this as the explicit trade-off of choosing the smaller fix.

## Smoke tests run (Pass 2)

- Full diff read of `874b814e..61ed8e11` (both files, every hunk).
- Traced all 4 `rebuildOverlays` trigger sites (`handleRegionChanged`, `handleSegmentsChanged`, `handleTimerTick`, `handleSelectionChanged`) to confirm the new gate touches exactly one of them.
- Traced the `onConfirm` closure's statement-by-statement execution order to confirm `resolvedTarget` reads `parkUntilTarget` *after* `rebuildOverlays` has synchronously completed, not before.
- Direct string comparison of the legacy toast branch against the pre-fix literal (not just "looks similar" — confirmed identical interpolation and surrounding text).
- Re-ran the compile-failure-class scan against the fix diff specifically.
- **Still not run — no Xcode/simulator in this sandbox:** the PR's `xcodebuild ... build test` command and the (now 11-step, Pass 1 added 3) live-UI smoke script. This remains the only open gate; it was never a code-correctness question, and both 🟡s from Pass 1 are now closed on the merits.

## What's working (Pass 2)

- The builder correctly chose the smaller, safer fix for #2 (toast copy, not reachability gating) and was explicit in the commit message and the updated doc comment about what trade-off that represents — exactly the kind of disclosed deviation this repo's process expects, not a silent judgment call.
- Both new pure functions are directly unit-tested without needing a live `ContentView`, consistent with this file's established "extract the decision" convention, and the tests target the actual regression surface (byte-identical legacy path, binary gate correctness) rather than restating the implementation.
