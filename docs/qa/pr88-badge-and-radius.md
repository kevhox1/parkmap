# PR #88 QA — badge-clear + browse sheet corner-radius

**Reviewed:** branch `fix/badge-clear-and-sheet-radius` at `03123a5b`, against Kevin's PR description (no standalone spec doc — two point fixes)
**Verdict:** MERGE

## Summary

Both fixes are small, correctly scoped, and additive-only (88 insertions, 0 deletions across 3 files — nothing pre-existing was touched or removed). The badge-clear call lands at the tail of the `.active` scenePhase branch, unconditional, non-blocking, and error-handled by logging only — it cannot disturb or gate anything that runs before it in that branch. The corner-radius fix is scoped to exactly the one `ActiveSheet` case it targets; the other 11 sheets at `.presentationCornerRadius(20)` are untouched. Working tree matched `HEAD` on checkout, no drift. Kevin's Mac build (805/0 tests, iPhone 17 / iOS 26.5) is the compile/test signal of record — this review is a correctness read of the diff only.

## Acceptance criteria checklist

- [x] Badge cleared on foreground — `NotificationScheduler.shared.clearBadge()` added as the last statement in `ContentView.handleScenePhaseChange`'s `.active` branch (`ContentView.swift:2747`), reached whenever `newPhase == .active`, no additional gating.
- [x] `clearBadge()` routes through the existing injectable seam — `center.setBadgeCount(0, withCompletionHandler:)` (`NotificationScheduler.swift:493-497`), same pattern as every other method on the class.
- [x] Failure path is non-fatal — completion handler only `print`s on error, never throws/asserts/blocks (`NotificationScheduler.swift:494-496`).
- [x] `browseNav` sheet gets an explicit corner radius — `.presentationCornerRadius(Self.browseSheetOuterCornerRadius)` added to `browseNavigationSheetContent` (`ContentView.swift:1347`), the only sheet builder touched.
- [x] No other sheet's radius changed — verified all 11 other `.presentationCornerRadius(20)` call sites are outside the diff hunks (`ContentView.swift:997,1030,1054,1082,1103,1128,1162,1224,1253,1401,1430`).
- [x] New badge test exists and exercises the seam correctly (`NotificationSchedulerTests.swift:1140-1150`).

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
None.

### 🟢 Minor / nit

- **#1: Doc comment on `browseSheetOuterCornerRadius` is now stale**
  - Where: `ContentView.swift:1377-1380`
  - What: The comment reads `[COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK] — this machine has no simulator. Kevin/QA: eyeball...` — but Kevin has already built and smoke-tested this on his Mac (per the task brief: "still looks similar to before," under active discussion re: `20` + capsule search field). The comment reads as if verification hasn't happened yet.
  - Expected: Not a functional bug — just a comment that will mislead the next reader into thinking this is unverified, when in fact it's verified-and-contested (design tension, not open correctness question).
  - Owner: `@ios-engineer` (fold in next time this file is touched; not worth a standalone PR).

### 💡 Out of scope (logged, not fixed)

- **Design tension on the `26` value.** Per the task brief: this makes `.browseNav` visibly rounder than all 11 other sheets, and Kevin has already flagged on-device that it "still looks similar to before." A follow-up (possibly `20` + a capsule-shaped search field) is under active discussion. Not resolving or recommending a value here — the *mechanism* (constant applied to the right sheet, derivation math checks out against the actual `cornerRadius: 10` / `.padding(.horizontal, 16)` values in `BrowseSearchAreaView.swift:295-300`) is correct; the *value* is a live design call, not a QA finding.
- **Badge-clear unit test only proves the seam is wired, not that the OS actually clears the badge.** `testBadgeFix_ClearBadge_CallsSetBadgeCountZero` (`NotificationSchedulerTests.swift`) asserts `MockNotificationCenter.badgeCountCalls == [0]` — this is consistent with every other test in this file (all of them assert against the mock, since real `UNUserNotificationCenter` can't be exercised in XCTest without device permissions), so it's not a regression in rigor, just an inherent unit-test ceiling. Real-device confirmation (badge actually goes to 0 on foreground) rides on Kevin's on-device pass, not on this test.

## Specific answer: did the badge-clear insertion disturb anything else in `.active`?

No. Read the full branch (`ContentView.swift:2712-2748`):

```
guard newPhase == .active else { return }
bannerState = ...                              // banner refresh
notificationsMuted = ...                       // mute re-sync
reminderOffsets = ...                          // FT-6 reminder re-sync
if let target = parkUntilTarget, ... { ... }   // stale-target guard
routePendingDeepLink(...)                      // deep-link replay
pinService.reconnectRealtime()                 // Realtime reconnect
Task { await pinService.refetchCurrentRegion() } // one-shot re-fetch
NotificationScheduler.shared.clearBadge()      // <- new, last statement
```

- It's appended strictly after every pre-existing effect, not interleaved — nothing earlier in the branch is delayed, reordered, or made conditional on it.
- `clearBadge()` itself does not `await` (fire-and-forget completion handler, same shape as the rest of `NotificationScheduler`'s async calls elsewhere in this file), so it can't block the synchronous tail of the branch or the `Task { ... }` refetch above it.
- It's not gated behind any of the earlier branch conditions (mute state, `parkUntilTarget`, deep-link presence) — it runs unconditionally on every `.active` transition, which is correct per spec intent ("once the user opens the app they've seen whatever fired").
- `.active` firing at cold launch (via `onChange(of: scenePhase)`'s initial transition) is pre-existing behavior shared by every other line in this branch — `clearBadge()` running there too is not a new risk class, and is in fact the correct behavior (badge should clear on the very first foreground, not just subsequent ones).
- `NotificationScheduler.shared` is a `static let` singleton with a no-arg `private init()` that only sets `center = UNUserNotificationCenter.current()` — there's no "not yet configured" state to race against; it's safe to call from the first `.active` transition.

## Also checked (per task brief)

- **Memberwise-init trap**: `browseSheetOuterCornerRadius` is `private static let` (`ContentView.swift:1381`), a type property, not an instance stored property — Swift's synthesized-memberwise-init exclusion for defaulted `let`s applies only to instance properties of structs used via an implicit initializer. `ContentView` is a SwiftUI `View` struct that doesn't rely on a memberwise init for this property anyway (it's `private`). No issue.
- **`TileLoader.swift` / `MapViewRepresentable.swift`**: confirmed untouched — `git diff main...HEAD --stat` shows only `ContentView.swift`, `Services/NotificationScheduler.swift`, `WeParkTests/NotificationSchedulerTests.swift`. No overlap with PR #89.
- **FT-20 confirmed-working set** (`.onGeometryChange` search-field measurement, conditional action-content rendering, `.presentationBackground(.regularMaterial)`, `ft20BrowseSheetEnabled`): the diff is purely additive (0 deletions), and the two touched regions are (a) one new modifier line appended after `.presentationDragIndicator(.visible)` and before `.interactiveDismissDisabled(true)`, and (b) one new `private static let` declaration — neither intersects any of the above. Nothing in that set was moved, deleted, or reordered.

## Smoke tests run

No simulator/Xcode available on this VPS (Linux) — did not attempt to build or run tests, per task constraints. This review is a static read of `git diff main...HEAD` plus targeted greps to verify claims made in the PR's own doc comments (corner-radius values, padding values, call-site counts, singleton init shape) against the actual source. Compile/test status (805/0 passed) is taken as reported by Kevin from his Mac build, not independently re-verified.

## What's working

- Both fixes are minimal and additive — easy to review, low blast radius, no stray edits.
- The badge fix's root-cause narrative (nothing ever called the clear API, so the badge was permanently stuck from the very first reminder) checks out against the code: `content.badge = 1` is set in `buildContent` and there was genuinely no counterpart clear call anywhere in the pre-PR tree.
- The doc comments on both fixes are unusually thorough and made independent verification fast — the corner-radius derivation, in particular, cites exact values (`cornerRadius: 10`, `.padding(.horizontal, 16)`) that were verifiable by grep and matched.
- Test added for the new behavior, following the existing DI/mock pattern in the file rather than inventing a new one.
