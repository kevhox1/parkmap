# PR #106 QA — My Car status line + ASP suspension note + long-press tentative pin

**Reviewed:** branch `ios/core-parking-16` at `d4d03408` (+ docs-only `90e777fc`), against `docs/open-items.md` #16 / #17-residual, `HANDOFF.md`'s 2026-09-11 entry.
**Pass 1 verdict:** 🔴 BLOCK (see below). **Pass 2 verdict (fix commit `036f2131`): ✅ MERGE-READY** — jump to the "Pass 2" section at the bottom for the current status; the rest of this file is the original Pass 1 report, left intact for history.

This is a static/code review pass — no Swift toolchain here. Everything below is traced through the actual engine code and a real scan of the bundled tile data, not just the diff.

## Summary

Item #17 residual (tentative long-press pin) is a clean, well-scoped port of the existing `DraftSpotPinAnnotation` add/remove pattern — flag gate is correct, no camera mutation, no leak paths I can find. Item #16 (My Car status line) correctly reuses `nextRestriction`/`nextRestrictionTimeLabel` as specced and is genuinely NOT flag-gated as required — but the engine's own, intentional, documented decision to treat `METERED` as "not a move-your-car restriction" (skipped entirely inside `nextRestriction`) means the new bold status line renders **"Free — no restrictions here"** on any block whose only rule is a meter — including while the meter is actively running and the existing (unchanged) headline directly above it correctly says **"paid until 7pm."** I scanned a 300-tile sample of the app's own bundled data: **753 of 12,659 rule-bearing segments (~6%) carry ONLY a metered rule**, including Fifth Avenue frontage — this is not an edge case. This directly reintroduces the class of bug FT-9 was created to fix (`docs/qa/ft9-bowery-2ndave-investigation.md`), at a new call site the FT-9 fix never touched.

## Acceptance criteria checklist (from PR body)

- [x] My Car sheet shows a status line directly under "Parked Xh ago" for both `communityEnabled` false/true — verified by code read; zero `communityEnabled` references inside the new `ParkedCarDetailView.swift` code paths (only in a comment)
- [x] Status line derived via `nextRestriction`/`nextRestrictionTimeLabel`, not a re-derivation of `safetyLabel` — verified; `ParkedCarDetailLogic.freeUntilStatusText` takes a `NextRestriction` + a caller-supplied time-label string, no engine logic duplicated
- [ ] Status line correctly represents "when does this become not-free" — **FAILED for metered-only segments. See Finding #1.**
- [x] ASP-suspended-today note appears only when segment has ASP rule AND today is suspended, reusing `ASPBanner`'s copy/color — verified; `.green`/`.white` matches `ASPBanner.todaySuspended` exactly, `segmentHasASPRule` scoping confirmed correct
- [x] Rules list collapses behind "Rules (N)" past 3, ≤3 stays always-visible — verified; `shouldCollapseRules(count:)` boundary tested at 0/3/4/9, matches `count > 3`
- [x] `resolvedSegment == nil` renders none of the new UI — verified by construction (both new blocks are inside `if let seg = resolvedSegment`)
- [x] No avoid/ticket/fine/evasion/dodge copy — verified, full-diff grep clean
- [x] Tentative marker appears exactly when the flag-on card is up, at the pressed coordinate — verified; `pendingParkCoordinate` is driven directly off `pendingLongPressCoord` through the pure gate
- [x] Marker removed on Cancel; no double-marker with the real car pin on Confirm — verified; `pendingLongPressCoord = nil` fires synchronously in `onConfirm` before `confirmLongPressPark` opens the `ParkConfirmView` sheet, and `syncPendingParkPin`'s add/remove-diff correctly handles the re-press-elsewhere case too (removes old, adds new, no leak)
- [x] Flag-off long-press flow byte-identical — verified; `pendingParkPinCoordinate(communityEnabled:false, ...)` always returns `nil`, tested for both coordinate-present and coordinate-absent cases (the exact scenario the gate exists for)
- [x] `updateUIView` still mechanical add/remove only, no camera mutation — verified; grepped diff for `setRegion`/`setCamera`/`setVisibleMapRect`, none added

## Findings

### 🔴 Blocking

- **#1: New "Free — no restrictions here" status line contradicts the existing "paid until Xpm" headline on metered-only blocks — hits ~6% of real segments, not flag-gated**
  - Where: `ParkedCarDetailLogic.freeUntilStatusText` (`ios/WePark/WePark/Views/ParkedCarDetailView.swift`), consuming `ParkingRulesEngine.nextRestriction` (`ios/WePark/WePark/Services/ParkingRulesEngine.swift:161-229`, comment at line ~225: `// METERED: skip (not a move-your-car restriction)`)
  - What: `nextRestriction` deliberately ignores `METERED` rules when computing "next restriction" — this is correct, intentional, pre-existing engine behavior (meters aren't a move-your-car event). But the new status line takes `nextRestriction`'s output at face value: for a segment whose *only* rule is `METERED`, `nextRestriction` returns the `hours == 168` "unrestricted" sentinel, and `freeUntilStatusText` renders **"Free — no restrictions here"** — bold, colored via `engine.currentStateColor`, directly under the parked-at row. The pre-existing headline immediately above (`safetyLabelView`, unchanged by this PR, calling `engine.safetyLabel`) correctly reports **"paid until 7pm"** while the meter is actively running (it uses the separate `meteredStatus()` function, which this new status line never consults). Result: the sheet displays, stacked, "paid until 7pm" then bold "Free — no restrictions here" for the same block at the same instant. During off-peak metered hours the contradiction is softer but the defect is the same in kind: the new line answers "when does this become not-free" with "never" while the actual answer (meter resumes at 9am) is known to the engine and displayed nowhere in the new feature — the one feature whose entire job is to answer that question.
  - Expected: the status line should either (a) fall back to `engine.meteredStatus(for:at:)`-derived wording when the segment's rules are metered-only / when a meter is actively running, or (b) at minimum not claim "no restrictions here" while a meter is running (this is the exact case `safetyLabel`'s FT-9 fix exists to get right — see `docs/qa/ft9-bowery-2ndave-investigation.md`). This is a sibling of the FT-9 bug at a new call site the FT-9 fix never touched.
  - Repro (static): pick any bundled segment whose `rules` array contains exactly one `METERED`-category rule (753 exist in a 300-tile sample scanned during this pass, e.g. 5TH AVENUE frontage in `tile_29_21.json`). Park a test car there during that meter's active hours. Sheet shows "paid until 7pm" (headline) directly above bold "Free — no restrictions here" (new status line).
  - Why it's blocking, not significant: item #16 ships to 100% of users, flag-off included — it is not behind `communityEnabled`. It is also the PR's stated centerpiece ("the sheet's single most valuable fact"). A driver who trusts the loud, bold new line over the plain-text headline above it could reasonably conclude they don't need to feed the meter, on a non-trivial fraction of NYC blocks.
  - Owner: `@ios-engineer`

### 🟡 Significant

- **#2: New `ParkedCarDetailView.aspService` default creates a second, redundant `ASPSuspensionService` instance per sheet-open — and the PR's stated rationale for this is factually wrong**
  - Where: `ParkedCarDetailView.swift` init, `aspService: ASPSuspensionService = ASPSuspensionService()`; call site `ContentView.swift:1219` (`ParkedCarDetailView(...)`) never passes `aspService:`
  - What: the PR's own doc comment says: *"`ContentView` never needs to pass this explicitly since it doesn't otherwise hold an `ASPSuspensionService` reference reachable from this sheet's call site."* That's incorrect — `ContentView.swift:488` already holds `@State private var aspService = ASPSuspensionService()` (built for the W7 top banner). The new code doesn't reuse it; it silently constructs a second, independent instance that re-reads and re-decodes `asp-2026.json` from the bundle on every My Car sheet presentation, on top of the THIRD copy already hidden inside `ParkingRulesEngine`'s own default init (`ContentView.swift:410`, `engine = ParkingRulesEngine()`, which defaults its own `aspService: ASPSuspensionService = ASPSuspensionService()`). This PR doesn't create that pre-existing triplication, but it adds a third redundant instance instead of threading the one that's sitting right there in the same file, and the doc comment's justification for not doing so is simply wrong.
  - Impact: no observable output divergence today (the calendar is static/immutable and all three instances parse the identical bundled file), so this is not a 🔴 — but it's wasted JSON parse work on every sheet-open and it violates this codebase's own stated single-instance-per-service convention (`NotificationScheduler.shared`, the existing `aspService` @State).
  - Expected: `ParkedCarDetailView(..., aspService: aspService, ...)` at the `ContentView.swift:1219` call site, reusing the existing instance.
  - Owner: `@ios-engineer`

### 🟢 Minor / nit

- **#3: Active-now status line is redundant with the headline directly above it** — PR's own flagged judgment call #2. When `restriction.isActiveNow`, the new line falls back to `restriction.label` verbatim (e.g. "No parking active now"), which reads as a near-duplicate of the existing headline's "No parking" one line up. Not misleading, just redundant. Agree with the PR's own reasoning that inventing new "restricted" vocabulary would be worse — recommend a follow-up to either suppress the new line in this one case (headline already covers it) or fold the two into one row, but not blocking.
- **#4: `DisclosureGroup`'s built-in accessibility trait is overridden by a hand-written `.accessibilityLabel`** on the "Rules (N)" collapse control — check on live smoke that VoiceOver still announces it as a disclosure control that can be double-tapped, not just as static text.

### 💡 Out of scope (logged, not fixed)

- The ASP-suspension badge (and the `ASPBanner` copy it reuses verbatim) never mentions that ASP suspension does NOT suspend meters. This is a pre-existing gap in `ASPBanner`'s copy (accessibility text: "No need to move your car" — true for ASP, silent on meters), not introduced by this PR, and the PR's judgment call to scope the badge to ASP-bearing segments only is the right call given Kevin's wording ("overlay all ASP conditions, including suspensions"). Worth a future pass: on a segment that carries BOTH an ASP rule and a metered rule, on a suspension day, should the sheet clarify "ASP suspended, but the meter still runs"? Flagging for a future session, not this PR's scope.

## Judgment-call assessments (from PR body)

1. **Verbose "Free until Thursday 9:30 AM" vs abbreviated "Thu 9 AM"** — Agree. Reusing the engine's own established `nextRestrictionTimeLabel` format verbatim (rather than inventing a new abbreviated formatter) is the right call and matches the task's own instruction to reuse label-producing APIs.
2. **Active-now fallback wording redundant with the sheet's headline** — Agree it's redundant (see Finding #3, 🟢); the PR's own reasoning for accepting the redundancy over inventing new vocabulary is sound. Not blocking.
3. **ASP-suspension note scoped to ASP-carrying segments only** — Agree. Showing "ASP Suspended" on a block with no ASP rule at all would be actively wrong, not just noisy. The open item's wording doesn't resolve this either way, and the PR's resolution is the only one that avoids surfacing a false claim. The meter-vs-suspension distinction this raises (see "Out of scope" above) is real but is a pre-existing `ASPBanner` copy gap, not something this PR needs to solve.
4. **Capsule badge vs full-width banner** — Agree. Matches the sheet's existing `SweptBadgeView` idiom; reuses `ASPBanner`'s exact copy/color so there's no new color mapping. Confirm white-on-green contrast reads fine in the live screenshot (should be — same values as the already-shipped top banner).

## Test-count reconciliation

- `main` baseline: `git grep -h -E '^\s*func test' origin/main -- ios/WePark/WeParkTests | wc -l` → **1282** (matches HANDOFF's S13c-merged figure)
- PR branch: same command against `origin/ios/core-parking-16` → **1303**
- Delta: **+21**, matches the PR's claimed breakdown exactly: 17 in `ParkedCarDetailCoreParkingTests.swift` + 4 in `PendingParkPinCoordinateTests` (`LongPressParkPopupTests.swift`)
- All 21 new tests are pure-function tests (`ParkedCarDetailLogic.*`, `ContentView.pendingParkPinCoordinate`) parameterized explicitly by their inputs, including the flag value — none of them read `AppConstants.communityEnabled` implicitly, so none of them are expected to behave differently between a flag-off and flag-on build.
- **No test in this PR exercises a metered-only segment against `freeUntilStatusText`/`nextRestriction`** — Finding #1 would not have been caught by this suite as written, static or on-device.

## Standard sweeps

- `Calendar.current`: zero occurrences in the diff (only a doc-comment restating the house rule) ✓
- Banned copy (avoid/ticket/fine/evasion/dodge): zero occurrences in the diff ✓
- Curb palette (`ParkingColors`/palette docs): untouched — zero diff ✓
- `supabase/`: zero diff ✓
- `docs/open-items.md`: both #16 and #17 annotated with PR #106 specifics, not marked closed (correct — closure happens at merge per the file's own convention) ✓
- Compile-failure classes checked:
  - Labeled-arg / memberwise-init order: `Segment(...)` and `ParkingRule(...)` calls in the new test file match their declared initializer parameter order exactly ✓
  - `nonisolated static` pure functions: `freeUntilStatusText`, `shouldCollapseRules`, `segmentHasASPRule`, `aspSuspensionNote`, `pendingParkPinCoordinate` all correctly `nonisolated static`, matching the established pattern (`longPressPresentationMode`, `mapMarkerTypes`) ✓
  - XCTestCase class-name collisions: no name clash between the 4 new test classes and any existing class on `main` ✓
  - Contextual-type-on-literal: no bare numeric/string literals in ambiguous contexts spotted in the new code ✓

## Smoke tests run

This was a static/code review pass — no Swift toolchain available on this VPS. No build, no simulator, no screenshot was taken. Everything above is a code-level trace against the actual `ParkingRulesEngine`/`ASPSuspensionService`/`MapViewRepresentable` implementations on this branch, plus an independent script-based scan of 300 randomly sampled bundled tile files (12,659 rule-bearing segments) to size Finding #1's real-world frequency (753 metered-only segments, ~6%, including confirmed Fifth Avenue frontage).

Not verified — recommend the Mac gate covers all of these explicitly:
- Build (`xcodebuild build`) and full test run in both flag states.
- Live My Car sheet visual check on an actual metered-only block (Finding #1) — this is the one item that most needs eyes on a real screen, since the contradiction is a rendering/wording issue a build log can't catch.
- Live long-press tentative-pin cycle (appear/cancel/replace) and flag-off dialog untouched.
- Rosh Hashanah suspension-day smoke if gating on 2026-09-12 (see Mac gate checklist below).

## Mac gate checklist (Pass 1 — superseded by Pass 2's counts below; kept for history)

1. **Build**: `xcodebuild -project ios/WePark.xcodeproj -scheme WePark -destination 'platform=iOS Simulator,name=iPhone 15' build` (resolve UDID dynamically per project convention, not hardcoded).
2. **Test counts** — run `xcodebuild test` twice, once per flag state (`AppConstants.communityEnabled` in `ios/WePark/WePark/Services/Constants.swift:154`):
   - **Flag-off** (`communityEnabled = false`): expect **1303/1303 passed**. None of the 21 new tests read the flag implicitly, so there should be zero new failures in this build.
   - **Flag-on** (`communityEnabled = true`): expect **1299 passed / 4 failed**, all 4 the SAME pre-existing named dark-ship guard failures from the S13c gate (main's flag-on split was 1278 passed + 4 named guards / 1282 total — reconcile the 4 failing test names against that same roadmap entry, not just the count). If any NEW test fails in the flag-on build, or the guard-failure count changes from 4, stop and investigate before merge — that would mean something in this PR is flag-dependent when it's specced not to be.
3. **Live smoke — My Car sheet (item #16), the merge-blocking part**:
   - Park a test car on a block with **≤3 rules** — confirm rules list is always-visible (no disclosure chrome).
   - Park a test car on a block with **>3 rules** — confirm "Rules (N)" disclosure appears collapsed by default, expands/collapses on tap.
   - Park a test car on a block whose **only rule is METERED**, during that meter's active/paid window — this is Finding #1's exact repro. Confirm whether the sheet shows the contradictory "paid until Xpm" + "Free — no restrictions here" stack described above. If it does, this PR should not merge until fixed (or Kevin explicitly accepts the finding and waives it — his call, not this QA pass's).
   - **If gating on 2026-09-12 (tomorrow's real Rosh Hashanah ASP-suspension day)**: park a test car on a block that carries an ASP rule — confirm the green "ASP Suspended — Rosh Hashanah" capsule badge renders live under the status line. Park a second test car on a block with rules but NO ASP rule — confirm the badge does NOT appear (Finding-free, per judgment call #3's scoping).
4. **Live smoke — long-press tentative pin (item #17 residual)**:
   - Flag ON: long-press the map → confirm the blue dimmed `car.fill` marker appears exactly at the press point alongside the `LongPressParkConfirmCard`.
   - Tap Cancel → confirm the marker disappears, no residual annotation.
   - Long-press again, tap "Park here" / Confirm → confirm the tentative marker is gone and the real `CarPinAnnotation` appears only after the subsequent `ParkConfirmView` sheet's own confirm — never both markers visible in the same frame.
   - Long-press, then (without cancelling) long-press a second, different point → confirm the tentative marker moves to the new point with no duplicate left behind at the first point.
   - Flag OFF: long-press the map → confirm the legacy three-button dialog appears exactly as before this PR, with **no** tentative marker ever drawn.
5. **Mount-chain glance**: since this PR touches `MapViewRepresentable.swift` and `ContentView.swift`'s overlay/annotation layer, take one full-screen screenshot with the app in its normal browse state and confirm the toolbar/chrome (Report pill, "?" button, recenter stack) all still render — this PR's diff to `updateUIView` is additive-only (`register` + one new `sync` call) but the standing rule after W8.5c-polish is to verify this live, not trust the diff.

## What's working

- The engine-reuse discipline on item #16 is genuinely good: `freeUntilStatusText` is a pure function over `NextRestriction` + a caller-supplied `String`, with zero engine logic duplicated and zero new date/calendar math — exactly what the spec asked for, and it's the same two-call family `NotificationScheduler` already uses, so the sheet and the scheduled reminder can never disagree on non-metered blocks.
- Item #17 residual is a clean, minimal-diff port of an already-proven pattern (`DraftSpotPinAnnotation`'s add/remove sync). The flag-off byte-identical requirement is enforced by a genuinely pure, well-tested gate function, and the double-marker-on-confirm race is closed by ordering (`pendingLongPressCoord = nil` before the sheet even opens), not by a fragile timing assumption.
- Test hygiene is solid: boundary tests at 0/3/4/9 for the collapse threshold, all 4 flag×coordinate combinations for the pin gate, and two tests against the REAL bundled `asp-2026.json` calendar (not just mocked reasons) for the suspension-note end-to-end path. The test-count math in the PR body is exactly right, which isn't always true of these self-reported deltas.
- `docs/open-items.md` annotations are accurate and appropriately left open (not force-closed) pending the Mac gate — good board hygiene.

---

# Pass 2 — verification of fix commit `036f2131`

**Reviewed:** `036f2131` (`036f2131~1..036f2131`) on `ios/core-parking-16`, addressing Pass 1's Finding #1 (🔴) and Finding #2 (🟡) above.
**Verdict:** ✅ MERGE-READY (pending the standard Mac gate — build/test/live-smoke was never run on this VPS for either pass; nothing below substitutes for it).

## Finding #1 fix — verified correct

- **Metered branch actually fires for metered-only segments**: `ParkedCarDetailLogic.segmentHasMeteredRule(_:)` is `segment.rules.contains { $0.category == .metered }` — correct against the rule model (`Category.metered` exists, matches `ParkingRule.category`). `statusLineView(for:)` now computes `meteredStatusLabel` by calling `engine.meteredStatus(for: seg, at: now)` when-and-only-when `segmentHasMeteredRule` is true, `nil` otherwise, and threads it into `freeUntilStatusText`. Traced end to end — this is the real call site, not just the pure function.
- **Mixed ASP+METERED still renders the ASP line**: confirmed by code trace, not just trusting the claim. `freeUntilStatusText`'s metered fallback is nested *inside* the `restriction.isUnrestricted` branch. For a segment carrying both an ASP-family rule and a metered rule, `nextRestriction` finds the ASP occurrence (ASP rules are never skipped, only METERED is) within the 14-day window in the overwhelming common case, so `isUnrestricted` is `false` and execution never reaches the metered fallback — the existing "Free until \<time\>" line renders unchanged. The new `testRealEngine_mixedASPAndMeteredSegment_stillRendersASPDerivedFreeUntilLine` test exercises this against the real engine (not a mock) and asserts `text.hasPrefix("Free until ")` — read the assertion myself, it's real.
- **`stripMeteredWrapper` byte-consistency**: read both implementations side by side.
  - Engine's private original (`ParkingRulesEngine.swift:633-642`): `hasPrefix("Metered (")` → drop prefix; `hasSuffix(")")` → drop last char.
  - New duplicate (`ParkedCarDetailLogic.stripMeteredWrapper`, `ParkedCarDetailView.swift`): identical two-step logic, only the local variable name differs (`lbl` vs `label`).
  - Verdict: functionally byte-identical today. **🟢 drift risk is real and worth naming**: these are two independently-maintained copies of the same string-transform with no shared test or compiler-enforced link between them. If the engine's private version is ever changed (e.g. a new `meteredStatus` output shape), this view-layer copy will silently diverge with no build-time signal — someone has to remember to update both. The `RuleRow.formatMinutes` precedent cited as justification has the same latent risk; this isn't a new pattern being invented, just a second instance of an existing one. Not blocking — logging as a nit for a future "shared internal formatting helpers" pass.
- **Unqualified "free"/"no restrictions" copy reachable for a metered segment — tried to construct a counterexample**: the one class of metered state I checked hardest was the "meter free right now" case (off-peak hours, `meteredStatus` returns e.g. `"Metered (free until 9am)"` / `"Metered (free)"` rather than `"Metered (paid until X)"`). Traced through `freeUntilStatusText`: `meteredStatusLabel` is non-nil whenever the segment has a metered rule, regardless of whether the meter is currently paid or currently free — so the fallback always fires and always goes through `stripMeteredWrapper`, producing `"free until 9am"` / `"free"` (lowercase, unwrapped) rather than the old blanket `"Free — no restrictions here"`. This is **honest**: it says "free" only when the meter itself is actually free right now, and still names the meter's own upcoming resume time when there is one (`"free until 9am"`) rather than claiming "no restrictions" outright. I could not construct a case where the fixed code claims "free"/"no restrictions" for a metered segment that is currently charging. The four new pure-function tests (`paidNow`, `freeUntil`, `freeForDays`, `plainFree`) cover all four of `meteredStatus`'s own output shapes and each asserts the exact stripped string, not just "doesn't contain X" — solid coverage.

## Finding #2 fix — verified correct

- `ContentView.swift:1219` now passes `aspService: aspService` (the pre-existing `@State private var aspService = ASPSuspensionService()` at `ContentView.swift:488`, built for the W7 banner) into the one real production call site of `ParkedCarDetailView`.
- Grepped every `ParkedCarDetailView(` call site on the branch tip: exactly two — the `ContentView.swift:1219` production call site (now fixed) and a `#Preview` block inside `ParkedCarDetailView.swift` itself (uses the default `ASPSuspensionService()` intentionally — previews have no `ContentView` instance to source one from, this is the correct/expected use of the default).
- **No second construction remains on the sheet's real runtime path.** The pre-existing THIRD copy hidden inside `ParkingRulesEngine`'s own default init (`ParkingRulesEngine.swift:54`) is untouched, as the commit message itself acknowledges — correctly out of scope for this fix (it predates this PR and isn't part of either finding).
- The corrected doc comment on `ParkedCarDetailView.aspService`'s declaration now accurately describes the default as existing for previews/tests only, not as a claim that no reachable instance exists — the factual error from Pass 1 is gone.

## Test claims — re-verified independently

- `git grep -h -E '^\s*func test' 036f2131~1 -- ios/WePark/WeParkTests | wc -l` → **1303** (matches Pass 1's PR-branch baseline exactly)
- Same command against `origin/ios/core-parking-16` (tip, i.e. `036f2131`) → **1314**
- Delta: **+11**, matches the commit message's breakdown exactly on inspection of the diff: 4 metered-only pure-function cases (`testUnrestricted_meteredOnly_paidNow_...`, `_freeUntil_...`, `_freeForDays_...`, `_plainFree_...`) + 5 `stripMeteredWrapper` unit tests + 2 real-`ParkingRulesEngine` integration tests (metered-only, mixed ASP+metered).
- **Assertion strength, read directly**: the regression-pinning assertions are strong, not weak placeholders —
  - `XCTAssertEqual(text, "paid until 7pm")` (exact string, not a substring/contains check) in both the pure-function test and the real-engine integration test.
  - `XCTAssertFalse(text.localizedCaseInsensitiveContains("no restrictions"))` and `XCTAssertFalse(text.localizedCaseInsensitiveContains("free"))` on the paid-now case, explicitly pinning the ABSENCE of the old buggy copy, not just presence of new copy.
  - These would fail against the pre-fix code: pre-fix, `freeUntilStatusText` had no `meteredStatusLabel` parameter at all (a compile-time break — the strongest possible "this test would have caught it" signal, since the old signature can't even be called this way), and semantically, the pre-fix logic for this exact input (`NextRestriction(hours: 168, ...)`, no metered awareness) produced literally `"Free — no restrictions here"`, which fails every one of the above assertions. Confirmed by reading, not assumed.

## Standard sweeps on the fix diff — all clean

- `Calendar.current`: zero occurrences (`git show 036f2131 | grep Calendar.current` — empty) ✓
- Banned copy (avoid/ticket/fine/evasion/dodge): zero occurrences in the fix diff ✓
- `AppConstants.communityEnabled` / the flag itself: zero references in the fix diff — `Services/Constants.swift` untouched, confirms item #16 stays non-flag-gated post-fix too ✓
- **Labeled-arg order risk (new `meteredStatusLabel` parameter)**: `freeUntilStatusText` gained a third parameter. Grepped every call site on the branch tip (1 production, 8 test call sites, all inside the same commit's diff) — every single one was updated in this same commit to pass `meteredStatusLabel:` as the third labeled argument, matching the new declared order (`restriction, timeLabel, meteredStatusLabel`). No stale call site left on the old two-argument signature (which would be a compile error, not a silent behavior change — but confirmed there isn't one to worry about).
- **`ContentView`'s new `aspService: aspService` argument position**: `ParkedCarDetailView.init` is hand-written (not memberwise) with declared order `parkedCar, engine, loadedSegments, parkPinService, scheduler, aspService, pinService, onDismiss, onClearPin, onOpenRestriction`. The call site omits the defaulted `scheduler:` and passes `aspService:` immediately after `parkPinService:`, preserving the relative declared order of the arguments it DOES pass explicitly (Swift requires this even with labels) — correct, would compile.

## Updated Mac gate checklist (supersedes the Pass-1 checklist's counts; live-smoke items below are still required — nothing in Pass 2 ran on hardware)

1. **Build**: `xcodebuild -project ios/WePark.xcodeproj -scheme WePark -destination 'platform=iOS Simulator,name=iPhone 15' build` (resolve UDID dynamically, per project convention).
2. **Test counts** — run `xcodebuild test` twice, once per flag state (`AppConstants.communityEnabled`, `Services/Constants.swift:154`):
   - **Flag-off** (`communityEnabled = false`): expect **1314/1314 passed**.
   - **Flag-on** (`communityEnabled = true`): expect **1310 passed / 4 failed**, the SAME 4 named pre-existing dark-ship guard failures from the S13c gate (`docs/community-2.0-roadmap.md`'s S13c row: "flag-on 1278+4 named dark-ship guards"). None of this PR's 32 new tests (21 from the feature commit + 11 from the fix commit) read the flag implicitly, so the guard-failure set should be unchanged by name and count. If the guard count or names shift, stop and investigate before merge.
3. **Live smoke — the one item Pass 2 could not verify (no toolchain here)**: park a test car on a real metered-only block (5th Avenue frontage is a good bet — QA's tile scan found several) during that meter's active/paid hours. Confirm the sheet now shows something like "paid until 7pm" for BOTH the existing headline AND the new bold status line (consistent, not contradictory) — this is the actual on-screen confirmation of Finding #1's fix; static review traced the logic correctly but a screenshot is the real proof.
4. **Live smoke — everything from Pass 1's checklist items 3-5 still applies unchanged** (rules-list collapse boundary, ASP-suspension badge on a real or simulated suspension day — 2026-09-12 Rosh Hashanah if gating tomorrow, long-press tentative-pin appear/cancel/replace cycle, flag-off dialog byte-identical, mount-chain chrome glance). Nothing in the fix commit touches `MapViewRepresentable.swift` or the long-press flow at all — re-confirmed via `git show 036f2131 --stat` (only `ContentView.swift`, `ParkedCarDetailView.swift`, and the test file changed) — so item #17 residual's live-smoke scope is unchanged from Pass 1.

## What's working (Pass 2 addendum)

- Both fixes are scoped exactly to what QA asked for — no scope creep, no unrelated refactors riding along. The fix commit message accurately cites the QA report by commit hash and addresses each finding in the order QA raised them.
- The four new metered-only pure-function tests don't just assert the new happy-path string — each one explicitly also asserts the ABSENCE of the old buggy copy ("no restrictions", "free" as a standalone claim), which is exactly the right regression-test shape: it fails loudly if someone reverts the fix later, not just if they change the new wording.
- The real-`ParkingRulesEngine` integration test for the metered-only case uses a March 2026 weekday specifically chosen to be "regular (non-suspended, non-holiday)" — shows the same holiday/suspension-boundary care this codebase's test suite generally applies elsewhere (e.g. Memorial Day fixtures in the original feature commit).
