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
