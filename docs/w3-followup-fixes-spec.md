# W3 Follow-up Fixes — Spec

**Status:** Open. Should be implemented as a standalone PR before W4 starts.
**Owner:** @ios-engineer (build) → @qa-verifier (pass-1) → squash-merge.
**Scope:** Three findings from `docs/qa/w3-pass-1-2026-05-10.md` that didn't block W3 merge but should be cleared before W4 piles new code on top of the same files (`ContentView.swift`, `ParkingRulesEngineParityTests.swift`).

This is **not a feature** — it's a follow-up cleanup PR. Spec is intentionally short. The QA report contains the full context; this doc names the fixes and the acceptance criteria.

---

## 1. Why a separate PR

W3 merged with three significant findings left open. Two of them (test-suite trustworthiness + AC-3 coverage gap) are correctness issues that compound with W4's tap-to-show-label feature — W4 verifies AC-3 character-for-character label parity, so the test suite must be a trustworthy regression gate before W4's QA pass uses it. The third (double `currentState` call per render) needs to land before W4's stress test on a real iPhone, because W4 doubles polyline density via the tap-target overlay and any per-frame waste compounds.

Cleanest sequence: fix these three things in a focused PR, get an independent QA pass, merge, then W4 starts on a clean baseline.

---

## 2. Fixes in scope

### Fix 1 — HP-11 test assertion is wrong, not the engine *(W3 QA #1)*

**File:** `ios/WePark/WeParkTests/ParkingRulesEngineParityTests.swift:564`

**Symptom:** `testHP11_ASPSuspendedSkipToNext` fails. `XCTAssertGreaterThan failed: ("19.5") is not greater than ("186.0")`.

**Root cause:** the test comment focuses on "next Fri May 22" being the first non-suspended ASP day, but `ASP_TUE_FRI` applies to Tuesdays too. From Mon May 18 noon ET, the next non-suspended `ASP_TUE_FRI` day is **Tue May 19** (not suspended) at 7:30am ET — 12h to midnight + 7.5h = **19.5h**. The engine is correct.

**Fix:**
- Change assertion bound from `> 186.0` to `> 19.0 && < 20.0` (or use `XCTAssertEqual(result.hours, 19.5, accuracy: 0.1)`).
- Rewrite the test comment to acknowledge May 19 Tuesday as the first non-suspended day. Suggested new comment:
  > Mon May 18 noon ET. `ASP_TUE_FRI` applies to both Tue + Fri. May 19 (Tuesday) is **not** in the suspension calendar, so the next active window starts Tue May 19 at 7:30am ET = 19.5h away. May 22 (Friday) is irrelevant for this test — it's a later candidate the walker never needs.
- Leave the May 24/25 `isSuspended` sub-assertions alone; they're correct.

**Acceptance:**
- `xcodebuild test -scheme WePark -destination 'platform=iOS Simulator,name=iPhone 17'` reports **42 passed, 0 failed**.

---

### Fix 2 — Add bare-FREE-segment parity test *(W3 QA #2)*

**File:** `ios/WePark/WeParkTests/ParkingRulesEngineParityTests.swift` (new test in `HappyPathParityTests`)

**Symptom:** AC-3 in `docs/ios-mvp-spec.md` §6 explicitly requires test coverage of "a FREE block." No test does this today.

**Fix:** add `testHP12_BareFreeSegmentReturnsFree`:
```swift
func testHP12_BareFreeSegmentReturnsFree() {
    let seg = makeSegment(rules: [rule(category: .free)])
    let result = engine.safetyLabel(for: seg, at: etDate(2026, 5, 11, 14, 0))
    XCTAssertEqual(result.text, "Free")
    XCTAssertEqual(result.severity, .free)
}
```

(Use existing `makeSegment` / `rule` helpers; the wall-clock time is arbitrary — a `.free` segment should return `"Free"` regardless of when you ask.)

**Acceptance:**
- New test passes.
- Total test count now **43 passed, 0 failed**.

---

### Fix 3 — Single `currentState` call per segment per render frame *(W3 QA #5)*

**File:** `ios/WePark/WePark/ContentView.swift:104-107`

**Symptom:**
```swift
let color = engine.currentStateColor(for: segment, at: now)
let isMetered = engine.currentState(for: segment, at: now) == .meteredActive
```

`currentStateColor` internally calls `currentState`, then `currentState` is called again on the next line. Each call walks the segment's rule set via `nextRestriction()`. For 40,000+ segments this doubles per-render work.

**Fix:** compute `currentState` once, derive both color and `isMetered` from it. Suggested shape:
```swift
let state = engine.currentState(for: segment, at: now)
let color = state.swiftUIColor   // already exists on CurrentState enum per palette doc §2.2
let isMetered = state == .meteredActive
```

If a free function `engine.currentStateColor(for:at:)` is still desirable for use outside the render loop, keep it — but the per-segment hot path in `ContentView` should not call it.

**Acceptance:**
- `git grep "engine.currentStateColor\|engine.currentState" ios/WePark/WePark/ContentView.swift` shows at most one call per segment per render frame.
- Polyline colors render identically (no visual regression).

---

## 3. Out of scope for this PR

- **W3 QA #4** (60s timer deviation from palette doc): the timer is a deliberate fill for the "app stays open and idle" case. Palette doc §2.2 was updated to note this is intentional. No action.
- **W3 QA #8** (accessibility labels on `MapPolyline`): there are no tap targets yet. Belongs to W4, where labels attach to the new tap targets at the point they're created.
- **W2/W3 stress test** on a real iPhone: belongs to W4 since the tap-target overlay doubles polyline count. Document the pre-W4 baseline frame rate here if you happen to measure it.
- **AC-3 PWA-snapshot parity** (W3 QA #3): reasoning-based test strings stay for now. A "live PWA snapshot capture" PR will land separately when Kevin runs the PWA + iOS side-by-side on a real device.

---

## 4. PR conventions

- Branch: `ios/w3-followups`
- Title: `fix(ios): W3 follow-ups — HP-11 assertion, bare-FREE test, single currentState call`
- Squash-merged via `gh pr merge --squash --delete-branch`
- `@qa-verifier` files `docs/qa/w3-followups-pass-1-2026-05-10.md` (or whatever date) verifying:
  - Test count is now 43, all passing
  - `currentState` is called at most once per segment per render frame in ContentView
  - No new `Calendar.current` use, no new `import SwiftUI` in `Models/`, no unrelated changes

---

## 5. Sizing

~30 minutes of `@ios-engineer` work. The fixes are well-localized and have no cross-file dependencies.
