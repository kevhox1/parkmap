# DM-2e Goal Engine QA Pass 1 — 2026-10-20

**Reviewed:** branch `feature/dm2e-goal-engine` at `20d30f10`, against `docs/drive-mode-default-spec.md`
§0.8.2–§0.8.5, §0.8.3a, the amendment banner's rulings block (ladder `offsetDays: 8→4→2`, Few Hours
= +3h strict), AC-14, AC-23–AC-26.

**Verdict:** 🔴 **FIX-THEN-MERGE**

## Summary

The `isFree(..., ignoringMeteredPayment:)` additive parameter (AC-23) is clean, correctly scoped to
only the metered branch, and the regression guard is real — I walked every branch of the pre- and
post-diff function and the `false` path is behaviorally byte-identical. AC-24 (day-boundary, any ASP
start hour) and AC-25 (ladder rungs + ranking) are solidly implemented and I independently re-derived
the day-math for three of the AC-25 test scenarios by hand; all check out. However, the "Good through
\<day>" ranking label (`ParkingGoals.nextMoveForcingDate` / `goodThroughLabel`) composes
`ParkingRulesEngine.nextRestriction(for:at:)`, and that function has a real, data-confirmed gap for
`NO_STANDING`/`SPECIAL` categories that are scheduled (not `anytime`) — it silently reports "no
restriction" for these, which the ranking code then treats as "indefinitely clear, outranks every
real date." I traced a concrete scenario where a segment that the PR's own ladder correctly ranks at
the **bottom** rung gets a ranking-label signal that says it's **better than every other matching
segment on screen**, a direct contradiction of AC-25's own requirement. This hits a real, non-trivial
share of the shipped tile data (100% of `SPECIAL` rules, ~41% of `NO_STANDING` rules in a 400-tile
sample are non-`anytime`/scheduled). This is the one blocking finding; everything else is solid.

## Acceptance criteria checklist

- [x] **AC-23** — `isFree(..., ignoringMeteredPayment: Bool = false)` default preserves pre-amendment
  behavior byte-for-byte. Verified by diffing the full function body line-by-line; the only change is
  one `if ignoringMeteredPayment { continue }` guard added at the top of the `cat == .metered` branch.
  Every other branch (ASP incl. suspension-skip, no standing, no parking, truck loading,
  time-range-overlap helper) is untouched. Existing call sites (`ContentView.swift:1941`,
  `:1956`) are **not present in the diff at all** — confirmed via `git diff main...PR -- ContentView.swift`
  returning empty output. `ParkUntilTests.swift` is **not present in the diff** — confirmed unmodified.
  The new `true`-path regression and positive-path coverage lives in a dedicated new file
  (`ParkingRulesEngineIgnoringMeteredPaymentTests.swift`), deliberately separate so the old file stays
  provably untouched.
- [x] **AC-24** — Free Overnight's target is `.nowET.startOfDayET(offsetDays: 2)`, a calendar-day
  boundary via the DST-safe `Calendar.easternTime` day-adding idiom (not a clock-hour cutoff).
  `testMatch_freeOvernight_aspTomorrowEarlyStart_nonMatching` (7:00–9:30am) and
  `_aspTomorrowLateStart_nonMatching` (11:30am–1pm) both correctly classify non-matching regardless of
  sweep start hour — exactly the two cases the task asked me to confirm are covered, and they are.
- [x] **AC-25** — Ladder `[8, 4, 2]` offsetDays, highest-first. I independently hand-traced three
  scenarios against the real day-walk algorithm in `isFree()` (Thu→Mon weekend gap /
  `clearsMiddleRung`, Sun start / `clearsBottomRungOnly`, metered-only / `clearsTopRung`) and all three
  match the test's asserted `clearedRungOffsetDays`. The ranking-comparison test
  (`testMatch_parkAndForget_topRungRanksAboveBottomRung`) correctly compares the numeric
  `clearedRungOffsetDays` field — **but see Finding #1**: the same test's second assertion
  (`nextMoveForcingDate` nil "unambiguously outranks" a bounded date) is the exact mechanism that
  breaks for the category this test doesn't exercise.
- [x] **AC-26** — Suspension-skip honesty verified against the **real** `ASPSuspensionService()`
  (loads the actual bundled `asp-2026.json`, not a mock/stub) and a **real** suspension date
  (2026-05-14, "Solemnity of the Ascension," confirmed present in
  `ios/WePark/WePark/Resources/asp-2026.json:19`). `testGoodThroughLabel_suspendedAspDaySkipped_resolvesToNextRealRestriction`
  asserts the label resolves past the suspended Thursday to the real following Monday — this is a
  genuine test against production data, not a mock that can't miss.
- [x] **AC-14** — No `Calendar.current` anywhere in the diff (`grep` clean across all 4 changed/new
  files). No `import SwiftUI` in `ParkingGoals.swift` (Foundation-only, verified). Both new test files
  use `WePark.Category` (qualified) in their `r(category: WePark.Category, ...)` helper signatures —
  the known bare-`Category`-ambiguity compile class is correctly avoided.
- [ ] **The ranking-label composition (§0.8.3a)** — FAILED for a real category. See Finding #1.

## Findings

### 🔴 Blocking

- **#1: `goodThroughLabel`/`nextMoveForcingDate` can rank the worst-matching segment as the best, for `NO_STANDING`/`SPECIAL` rules that are scheduled rather than `anytime`**
  - Where: `ParkingGoals.nextMoveForcingDate(for:from:engine:)` (`ios/WePark/WePark/Services/ParkingGoals.swift`), composing `ParkingRulesEngine.nextRestriction(for:at:)` (`ParkingRulesEngine.swift:161-229`).
  - What: `nextRestriction`'s loop has a real asymmetry — `NO_PARKING`/`TRUCK_LOADING` rules get a full forward walk via `computeHoursUntilActive` even when not active right now (line 196), but `NO_STANDING`/`SPECIAL` rules (line 180-187) **only** check "is this active right this instant" (`rule.anytime || isScheduleActive(...)`); if that's false, the function falls through with **zero** contribution to `soonestHours` — no `continue`, no forward walk, nothing. A scheduled (non-`anytime`) `NO_STANDING`/`SPECIAL` rule that isn't active *at the exact moment `nextRestriction` is called* is invisible to it. This is pre-existing, unmodified-by-this-PR code (it mirrors the already-shipped JS port, per the inline comment "Port of JS lines 5332-5336") — but this PR is the first to build a **ranking** feature directly on it, and the PR's own test (`testMatch_parkAndForget_topRungRanksAboveBottomRung`) asserts the resulting `nil` from `nextMoveForcingDate` "unambiguously outranks a bounded date" — i.e., encodes "no restriction found" (the sentinel) as *the best possible outcome*.
  - Concrete trace (worked by hand against the actual algorithm, not the test suite's own blind spot): segment has one rule, `NO_STANDING`, `days: [3]` (Wednesday only), `timeRanges: []` (all day Wed), no other rules. `from` = Monday 10:00am.
    - `isFree()` ladder (correct, this part of the PR is fine): rung `offsetDays: 2` (window ends Wed 00:00, excludes Wednesday) → clears. Rung `offsetDays: 4` (window ends Fri 00:00, includes all of Wednesday) → Wednesday's all-day no-standing rule conflicts → fails. So `match()` correctly reports `clearedRungOffsetDays == 2` — **the bottom rung, the worst matching tier.**
    - `nextRestriction(for: segment, at: Monday 10am)`: `cat == .noStanding`; `rule.anytime` is `false`; `isScheduleActive` checks `rule.days.contains(dayOfWeek)` → Monday (1) is not in `[3]` → returns `false`. The combined condition is `false`, so the early-return never fires — and (per the asymmetry above) **nothing else happens for this rule.** `soonestHours` stays at its initial `168`. `nextRestriction` returns the "no restriction found" sentinel.
    - `nextMoveForcingDate`: `guard restriction.hours < 168 else { return nil }` → `168 < 168` is false → returns `nil`.
    - Per the PR's own test's stated semantics, `nil` "unambiguously outranks" every bounded date — so this bottom-rung segment's ranking signal says it's **better than a segment that cleared the top (7-day) rung.** That is the exact inverse of AC-25's requirement ("a block that clears the top rung is labeled/ranked above one that only clears the bottom").
  - Data check (not hypothetical — I sampled the shipped bundle, not a claim): across a 400-tile / ~17,800-segment random sample of `ios/WePark/WePark/Resources/tiles/`, **100% of `SPECIAL` rules (799/799)** and **~41% of `NO_STANDING` rules (3,109/7,481)** are non-`anytime`/scheduled — real signs like `"NO STANDING SCHOOL DAYS 7AM-4PM"`, `"STAR (SYMBOL) AVO POLICE DEPARTMENT MONDAY-FRIDAY 7AM-7PM"`, bus-stop signs with 6-day (not Sunday) coverage. This is not a corner case; it's a mainstream restriction shape.
  - Expected: per §0.8.3a, "the genuinely-better ones [should be] distinguishable" with "an honest value line" — the label/ranking must never say a worse-clearing block is better than a better-clearing one.
  - Repro: construct the exact segment/date above (or run a variant of the existing `testGoodThroughLabel_suspendedAspDaySkipped_resolvesToNextRealRestriction` test but swap the rule for a non-`anytime` `NO_STANDING`/`SPECIAL` rule) and assert `nextMoveForcingDate` is non-nil and resolves to the actual Wednesday restriction. It will currently return `nil`.
  - Why this blocks (not just logs): this PR's own test suite bakes the broken behavior in as "verified correct" (the `topRungRanksAboveBottomRung` test only exercises a metered-vs-ASP pairing, never a `NO_STANDING`/`SPECIAL` pairing, so it can't catch this). DM-2 (not yet built) will consume `goodThroughLabel` directly for UI without re-deriving its correctness — shipping this now as "done" means the bug ships silently into the next PR's foundation, discoverable only after Kevin sees a backwards-ranked "Good through" label in a live smoke.
  - Owner: `@ios-engineer`
  - Suggested fix shape (not prescriptive — engineer's call): either (a) give `nextRestriction` a real forward walk for `NO_STANDING`/`SPECIAL` mirroring `computeHoursUntilActive`'s treatment of `NO_PARKING`/`TRUCK_LOADING` (bigger, touches already-shipped `nextRestriction`/`safetyLabel`/`currentState` behavior — needs its own regression care), or (b) stop composing `nextRestriction` for this feature and instead reuse `isFree()`'s own day-walk to find the next calendar date where `isFree(..., ignoringMeteredPayment: true)` flips from true to false — more new code, but correctly closed-form over the same categories `isFree()` already handles correctly for the match/bucket decision, with no dependency on `nextRestriction`'s asymmetry. Either way, add a `NO_STANDING`/`SPECIAL`-scheduled test case before this is trusted.

### 🟡 Significant

- **#2: `goodThroughLabel`/`nextMoveForcingDate` are goal-agnostic and always use `nextRestriction`'s built-in metered-skip — a latent trap if DM-2 calls them for "Free a Few Hours"**
  - Where: `ParkingGoals.nextMoveForcingDate(for:from:engine:)` — no `goal` parameter, so it can't derive the caller's metered-tolerance.
  - What: the function's doc comment says it's "exactly the predicate the overnight family of goals uses" but nothing in the type signature prevents a future caller from invoking it for Free a Few Hours. `nextRestriction` **always** skips `METERED` (line 226, unconditional `continue`), matching the overnight family's `ignoringMeteredPayment: true` semantics — but Few Hours is **strict** (`ignoringMeteredPayment: false`, Kevin's explicit ruling: "it's a meter so that's not free"). If DM-2 ever surfaces a ranking/"good through" style label for Few Hours matches, it would silently overpromise on a block with an active meter inside the window (e.g., "Good through [some later time]" on a block you'd actually owe money at within the hour).
  - Not reachable in this PR — no caller exists yet. Not blocking this merge.
  - Owner: `@ios-engineer` (for DM-2) — recommend either a doc comment stronger than the current one ("DO NOT call for `.freeFewHours`") or, better, having `GoalSelectorView` simply never call `goodThroughLabel` for that goal (there's nothing to rank in a flat 3-hour window anyway — every match clears the identical bar).

### 🟢 Minor / nit

- **#3:** `ParkingRulesEngine.swift` still has `import SwiftUI` at the top of the file (line 27) — a standing violation of AC-14's "no `import SwiftUI` in service files" rule. **Pre-existing, not part of this diff** (confirmed via `git diff main...PR -- ParkingRulesEngine.swift`, which only touches lines 656-770). Flagging for the record since AC-14 is explicitly cited as binding this PR, but this PR did not introduce or worsen it.
- **#4:** `NextRestriction.swift`'s doc comment says "168 = no restriction found... 14-day window," but `computeHoursUntilASP`'s internal walk is genuinely 14 days (`for offset in 0..<14`) while `nextRestriction`'s `soonestHours` is seeded at `168` (7 days) and only updates on a strictly-smaller value — so anything `computeHoursUntilASP` finds between day 7 and day 14 is silently discarded (never beats the seed). I verified this doesn't actually cause an AC-25 edge case today — it happens to coincide exactly with Park & Forget's own 7-day top rung, so a segment clearing the top rung correctly has nothing real inside 7 days to report either way — but the "14-day" framing is misleading, and `ParkingGoals.swift`'s own new doc comment repeats it verbatim ("nextRestriction's own 14-day ASP walker"). Pre-existing confusion, not a new bug, worth a follow-up comment fix.
- **#5:** `ParkingGoals.target(for: .parkAndForget, from:)` returns only the top (widest) rung's date, not the real per-segment ladder result — correctly and clearly documented in its own doc comment, but it's an easy footgun for a future caller who doesn't read the comment and assumes `target(for:)` is goal-complete for all three cases. No action needed now; just noting it's there.

### 💡 Out of scope (logged, not fixed)

- Fixing `nextRestriction`'s `NO_STANDING`/`SPECIAL` forward-walk gap at its root (Finding #1's underlying cause) is bigger than this PR's diff — it also feeds the already-shipped `safetyLabel`/`currentState` color system, so a fix needs its own regression pass against `ParkUntilTests.swift`/My Car sheet labels. Flagging so it doesn't get lost as "a ParkingGoals.swift problem" when it's really a `ParkingRulesEngine.nextRestriction` problem with a new, higher-stakes consumer.

## Smoke tests run

This is a pure engine/service-layer PR with no UI surface (`GoalSelectorView`/DM-2 is a separate,
not-yet-built PR) — no `.safeAreaInset`, `MapViewRepresentable.swift`, `ContentView.swift`, or
`Views/DriveMode*.swift` files are touched (confirmed via `git diff main...PR --stat`: only
`ParkingRulesEngine.swift`, `ParkingGoals.swift`, and two test files). Per the standing live-UI-smoke
gate, this PR class does **not** require a simulator build/screenshot — there is nothing new to render.
I did not build or launch the simulator for this pass; that gate applies to the next PR (DM-2) once it
exists.

What I did run/verify:
- Full line-by-line diff review of `ParkingRulesEngine.isFree` (before/after) — confirmed the
  regression guard claim by hand, not by trusting the PR description.
- Full read of `ParkingGoals.swift`, both new test files, and the pre-existing (untouched)
  `nextRestriction`/`computeHoursUntilASP`/`isScheduleActive` functions it composes.
- Independent hand-trace of 3 of the 5 AC-25 ladder test scenarios against the real day-walk algorithm
  (not just reading the assertions) — all matched.
- `grep` sweep for `Calendar.current` and `import SwiftUI` across all 4 changed/new files — clean.
- `grep` sweep for bare `Category`/`Protocol`/`Method`/`Ivar` in the two new test files — clean, both
  correctly use `WePark.Category`.
- Confirmed `ContentView.swift` and `ParkUntilTests.swift` have zero diff lines in this PR (byte-level
  "untouched" claim verified, not assumed).
- Confirmed `2026-05-14` ("Solemnity of the Ascension") is a real entry in the bundled
  `asp-2026.json`, so AC-26's test exercises real suspension data, not a mock.
- Sampled 400 of 1,079 bundled tile JSON files (~17,800 segments) with a one-off Python script to
  measure the real-world frequency of non-`anytime` `NO_STANDING`/`SPECIAL` rules — the basis for
  Finding #1's severity (not a guess).
- Confirmed the branch is a clean single commit, fast-forwardable from current `main`, no merge
  conflicts, no `project.pbxproj`/`Info.plist`/Config changes.
- **Not run:** `xcodebuild build`/`xcodebuild test` — no Swift toolchain available in this sandbox
  (`which xcodebuild swift swiftc` all fail). Compile verification (AC-14's "`xcodebuild test` exits
  0") is explicitly deferred to the Mac gate. Everything above is static/algorithmic review against
  the actual source, not a substitute for a real build — flagging this honestly rather than silently
  assuming it compiles. Based on this review I'd expect it to compile cleanly (constructors used only
  via JSON round-trip, not direct memberwise init; all cross-type parameter orders checked by hand;
  `nonisolated static` applied consistently), but that's a prediction, not a verification.

## What's working

- The one genuinely new piece of engine surface (`ignoringMeteredPayment`) is implemented exactly as
  scoped in §0.8.4 — small, additive, isolated to one `continue` inside one branch, with a dedicated
  separate test file specifically so the existing `ParkUntilTests.swift` provably stays untouched.
  This is the right way to ship an additive engine parameter.
- AC-24's day-boundary reasoning is implemented correctly and the tests specifically target the
  "early vs. late ASP start hour" distinction that's the whole point of using a calendar-day boundary
  instead of a clock-hour cutoff — this is the one thing the spec most wanted verified, and it's
  solid.
- AC-25's ladder and ranking-by-rung (`clearedRungOffsetDays`) are correct; I independently
  re-derived the day arithmetic by hand rather than trusting the test assertions and they hold up.
- AC-26 is tested against the real bundled ASP suspension calendar, not a mock — a meaningfully
  stronger test than it needed to be.
- Compile hygiene (no `Calendar.current`, no `import SwiftUI` in the new file, qualified
  `WePark.Category`, `nonisolated static` throughout, no shared XCTestCase helper-shadowing) is clean
  across the board — the engineer clearly worked from the project's known compile-failure-class list.
- The PR correctly keeps the two new streams (DM-2e's engine math, DM-2's future UI) file-disjoint per
  the spec's re-scoping note, and ships zero UI, so this PR's blast radius is exactly as advertised:
  engine-only, no regression risk to anything currently shipped.

---
*QA by @qa-verifier, cold read, no prior authorship context on this branch.*

---

# Pass 2 addendum — 2026-10-20

**Reviewed:** branch `feature/dm2e-goal-engine` at `0d7c8ca4` (fix commit on top of pass 1's
`20d30f10`), re-verified adversarially against the Pass 1 findings above.

**Verdict:** ✅ **MERGE**

## Summary

Both findings from Pass 1 are genuinely fixed, not just claimed-fixed. I re-ran my original
Finding #1 hand-trace against the new code **before** reading the new tests' assertions, to avoid
confirming my own trace against itself — the new `nextMoveForcingDate` walks calendar days directly
via `isFree(..., ignoringMeteredPayment:)` instead of composing `nextRestriction`, and my independent
trace produced the exact same dates the new tests assert (Wed 2026-05-13 for the NO_STANDING repro,
Fri 2026-05-15 for the new SPECIAL variant, Mon 2026-05-18 for the AC-26 suspension case) before I
looked at what the test file expected. `nextRestriction()` itself has zero diff across the entire PR
(verified via `git diff 20d30f10..HEAD -- ParkingRulesEngine.swift`, including the fix commit — empty
output). Finding #2 is closed cleanly: `goal:` is now a required (non-defaulted) parameter on both
ranking functions, threaded correctly through `ignoresMeteredPayment(for:)`, and every one of the 10
call sites across the test file was updated consistently. One new 🟢 nit (missing direct test for
`.freeFewHours` metered-strictness in the new ranking path) and the walk's own explicit 14-day
horizon cap are the only things I'd still note — neither blocks merge.

## Re-verification checklist (adversarial, per the coordinator's 6 items)

1. **Finding #1 re-trace against the NEW code** — ✅ confirmed fixed. I reconstructed my original
   Pass-1 repro (NO_STANDING, `days: [3]` only, `timeRanges: []`, `from` = Monday 10:00am) and walked
   the new `nextMoveForcingDate` by hand:
   - `dayOffset=0`: window `[Mon 10am, Tue 00:00)` — Wed not in range → clear.
   - `dayOffset=1`: window `[Tue 00:00, Wed 00:00)` — Wed excluded (half-open) → clear.
   - `dayOffset=2`: window `[Wed 00:00, Thu 00:00)` — Wed (day 3) ∈ rule.days, empty `timeRanges` → all-day conflict → `isFree` returns `false` → function returns `from.startOfDayET(offsetDays: 2)` = **Wed 2026-05-13 00:00**.
   This is non-nil and resolves to the real restriction day — the exact fix the finding asked for. It
   matches `testNextMoveForcingDate_scheduledNoStandingNotAnytime_findsRealRestriction_notNil`'s
   asserted `et(2026, 5, 13, 0, 0)` exactly — I derived this independently, then confirmed against the
   test, not the reverse.
   - Ranking check: `testMatch_parkAndForget_scheduledNoStandingBottomRung_doesNotOutrankTopRung` now
     correctly gets `bottomDate` = non-nil (the scheduled NO_STANDING segment) and `topDate` = nil (the
     metered-only segment) — under the established "`nil` outranks any bounded date" convention, the
     bottom-rung segment (real date) now correctly ranks **below** the top-rung segment (nil), which is
     the inverse of Pass 1's observed bug. Confirmed by hand, not by trusting the test name.
   - I additionally hand-verified the new SPECIAL-category test
     (`testNextMoveForcingDate_scheduledSpecialNotAnytime_findsRealRestriction_notNil`: `SPECIAL`,
     `days: [5]`, `timeRanges: [(600,720)]`, from Monday) — walking day-by-day lands on Friday
     2026-05-15 00:00, matching the test's assertion exactly.
2. **New day-walk's own edge cases:**
   - **Walk bound/cap:** `searchHorizonDays: Int = 14` (default), explicit named parameter, not a
     magic number. A no-rules segment: `isFree()` returns `true` immediately for empty rules
     (`guard !rules.isEmpty else { return true }`), so every one of the 14 iterations reports
     `clearThisDay = true`, the loop completes without ever returning early, and the function falls
     through to `return nil` — clean termination, verified by reading `isFree`'s own early-return
     path, not assumed.
   - **ET-midnight boundary / off-by-one:** `dayOffset == 0` uses `from` itself (not `from`'s midnight)
     as `windowStart`, so "today" only covers the time remaining from `from` onward — correct, it
     shouldn't flag a restriction earlier today that's already passed. All other days use
     `from.startOfDayET(offsetDays:)` for both window edges, so each subsequent day's window is a
     clean `[midnight, nextMidnight)` half-open interval with no double-counting or gap at the
     boundary. The `guard windowEnd > windowStart else { continue }` defensive check never actually
     triggers in practice (`startOfDayET(offsetDays:)` is monotonically increasing by construction),
     confirmed by inspection, not just taken on faith.
   - **DST transition days:** `startOfDayET(offsetDays:)` uses `Calendar.easternTime`'s
     `date(byAdding: .day, value:, to:)` (confirmed in `Date+ET.swift:83-88`, unchanged by this PR) —
     this is the DST-safe calendar-day idiom already used by `ParkUntilSheet.tonightMidnight()` and
     the ladder itself, not raw `addingTimeInterval(24*3600)` arithmetic. Calling `isFree()` once per
     narrow 1-day window doesn't introduce any new DST exposure beyond what the ladder's wider-window
     calls already had — `isFree()`'s own internal day-count math (`cal.dateComponents([.day], ...)`)
     is Calendar-based regardless of window width. No new DST risk from this refactor.
   - **Day-level precision vs. AC-26's honesty requirement:** re-verified by hand (see item 1's
     methodology) that the suspension test's updated expectation —
     `et(2026, 5, 18, 0, 0)` instead of the old `et(2026, 5, 18, 7, 0)` — is correct: the function now
     returns the ET midnight of the restriction's calendar day, not the rule's exact clock start time,
     and `relativeDayLabel`'s day-diff math only ever consumed the date portion anyway (confirmed by
     re-reading `relativeDayLabel`, unchanged by this fix) — so day-level precision loses no
     information the label actually used, and the suspension-skip (Thursday 05-14 correctly skipped,
     landing on Monday 05-18) still holds, now via `isFree`'s own ASP-suspension branch (`isSuspended`
     check) rather than `nextRestriction`'s. Same honesty guarantee, different (and now correct)
     plumbing.
3. **`goal:` parameter threading** — ✅ confirmed. Both `nextMoveForcingDate` and `goodThroughLabel`
   now require `goal: ParkingGoal` (non-defaulted — a caller cannot omit it), and internally call
   `ignoresMeteredPayment(for: goal)` — the same, unchanged, already-tested function `match()` uses,
   so there is exactly one source of truth for per-goal metered tolerance, not two that could drift.
   `ignoresMeteredPayment` itself is untouched: `.freeOvernight`/`.parkAndForget` → `true`,
   `.freeFewHours` → `false`. I grepped every `nextMoveForcingDate(`/`goodThroughLabel(` call site in
   the test file (10 total) — all pass `goal:` explicitly and in the correct label position; no stale
   call site was left without it (which would be a compile error, not a silent bug, but worth
   confirming directly rather than trusting the compiler would have caught it before I looked).
   **Minor gap (see 🟢 below):** no test directly exercises `nextMoveForcingDate(goal: .freeFewHours, ...)`
   against a metered-active segment to prove the strict path end-to-end through this specific
   function — the only direct proof is that it delegates to the already-tested
   `ignoresMeteredPayment`, which is a reasonable inference but not a direct assertion.
4. **`nextRestriction()` zero diff** — ✅ confirmed twice: once against the original DM-2e commit
   (`git diff 20d30f10..origin/... -- ParkingRulesEngine.swift` → empty) and now again including the
   fix commit (`git diff 20d30f10..0d7c8ca4 -- ParkingRulesEngine.swift` → empty). The entire PR,
   fix included, has made zero changes to `ParkingRulesEngine.swift` beyond the original `isFree`
   parameter addition reviewed in Pass 1. `safetyLabel`/`currentState`/My Car sheet labels (all
   downstream of `nextRestriction`) are provably unaffected by this fix.
5. **Blind-build compile-failure classes, re-scanned on the fix diff:**
   - Literal-receiver contextual types: `for dayOffset in 0..<searchHorizonDays` — `searchHorizonDays`
     is a typed `Int` parameter, no literal ambiguity.
   - Labeled-arg order vs. declaration: all 10 updated call sites (`for:goal:from:engine:[searchHorizonDays:]`)
     match declared order exactly — checked each one, not sampled.
   - Memberwise-init order: no new structs introduced in the fix diff.
   - XCTest extension helper shadowing: no shared helpers added; the three new test methods reuse the
     existing private `et`/`seg`/`r` helpers already scoped to this one test class.
   - Missing `nonisolated` on pure statics used in sync XCTests: both functions remain
     `nonisolated static func`, unchanged in that respect.
   - Bare `Category`/`Protocol`/`Method`/`Ivar`: re-grepped the full updated test file — zero bare
     occurrences, all `WePark.Category`.
   - `Calendar.current` / `import SwiftUI`: re-grepped the fix diff specifically (not just the whole
     file) — clean.
6. **Report location** — this Pass 2 addendum is appended to the same file,
   `docs/qa/pr129-dm2e-goal-engine.md`, below the original Pass 1 report, per the repo's addendum
   convention (matching `docs/qa/w8.5d-pass-2-2026-06-01.md`'s relationship to its pass-1 sibling, and
   this project's established "amend in place with a dated addendum section" pattern for the same
   report file rather than a separate pass-2 file for this particular PR).

## Findings (Pass 2)

### 🟢 Minor / nit

- **#6 (new):** No test directly proves `nextMoveForcingDate`/`goodThroughLabel` thread strict
  metered semantics end-to-end for `.freeFewHours` (e.g., a metered-active-in-window segment against
  `goal: .freeFewHours` asserting a non-nil/near-term date rather than skipping past the meter). The
  implementation correctly delegates to the shared, already-tested `ignoresMeteredPayment(for:)`, so
  the risk of this actually being wrong is low — but it's a one-line gap in otherwise-thorough
  coverage, and it's exactly the function this PR's own Finding #2 fix was about. Not blocking;
  recommend adding before DM-2 starts calling this for real.
- **#7 (carried forward, unchanged):** 🟢 Findings #3 (pre-existing `import SwiftUI` in
  `ParkingRulesEngine.swift`) and #5 (`target(for: .parkAndForget)` top-rung-only footgun) from Pass 1
  are untouched by this fix, as expected — re-confirmed still present, still non-blocking, still
  correctly out of this PR's actual scope to fix.
- **#8 (Pass 1 Finding #4, now effectively moot):** the stale "14-day window" doc-comment confusion
  flagged in Pass 1 no longer applies to `ParkingGoals.swift` — the rewritten `nextMoveForcingDate`
  doc comment no longer references `nextRestriction`'s 14-day/168h sentinel at all, since it no longer
  composes that function. The underlying `NextRestriction.swift` comment is still stale, but that's
  squarely in the 💡 out-of-scope bucket from Pass 1, untouched by (and irrelevant to) this fix.

### 💡 Out of scope (unchanged from Pass 1)

- `nextRestriction`'s own `NO_STANDING`/`SPECIAL` forward-walk gap (Pass 1 Finding #1's root cause)
  remains unfixed at the source — correctly so, since this fix's whole point was to stop depending on
  it rather than touch already-shipped, higher-blast-radius code. Still worth a dedicated follow-up
  for `safetyLabel`/`currentState`'s own (lower-stakes, pre-existing) exposure to the same gap, same
  as noted in Pass 1.

## Smoke tests run (Pass 2 additions)

- Re-derived the exact restriction dates for 3 scenarios (NO_STANDING/Wed, SPECIAL/Fri, ASP suspension/Mon)
  against the new day-walk algorithm **before** reading the corresponding test assertions, specifically
  to avoid rubber-stamping the builder's own stated fix.
- `git diff 20d30f10..0d7c8ca4 -- ParkingRulesEngine.swift` and the full-PR equivalent — both empty,
  confirming zero changes to `nextRestriction`/`isFree`/`computeHoursUntilASP` since Pass 1.
- `git diff 22361c93..origin/feature/dm2e-goal-engine -- ParkingGoals.swift ParkingGoalsTests.swift` —
  read in full, not just skimmed, for both the implementation and every updated/new test.
- Grepped all 10 `nextMoveForcingDate(`/`goodThroughLabel(` call sites in the test file individually
  for correct `goal:` threading and argument order.
- Re-ran the `Calendar.current`/`import SwiftUI`/bare-`Category` sweeps against the fix diff
  specifically.
- **Not run (same caveat as Pass 1):** `xcodebuild build`/`test` — no Swift toolchain in this sandbox.
  Static/algorithmic verification only; deferred to the Mac gate.

## What's working (Pass 2 additions)

- The fix doesn't patch around the symptom — it removes the dependency on the buggy composition
  entirely and reuses the SAME day-walk (`isFree`) that the ladder already trusted, rather than
  touching the higher-blast-radius, already-shipped `nextRestriction`. That's the right shape of fix
  for this finding.
- The builder clearly re-derived my exact repro (same segment shape, same `from` date) for the new
  regression tests rather than inventing a different, easier-to-pass scenario — `et(2026, 5, 11, 10, 0)`
  Monday, `NO_STANDING`/`days: [3]` is byte-for-byte my Pass 1 trace.
- The required (non-defaulted) `goal:` parameter is the right API shape for Finding #2 — it makes the
  old implicit-overnight-tolerance bug structurally impossible to reintroduce, not just documented
  against.
- Doc comments were rewritten, not just patched — the new `nextMoveForcingDate` doc comment explains
  both why it doesn't compose `nextRestriction` and cites the exact QA finding, which will save the
  next engineer who touches this file from rediscovering the same trap.

---
*QA Pass 2 by @qa-verifier, same reviewer as Pass 1, re-verified adversarially per the coordinator's
explicit instruction not to take the fix claims on faith.*
