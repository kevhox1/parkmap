# DM-3 Priming Card + enterCruiseMode() Auth Fix — QA Pass 1 — 2026-10-20

**Reviewed:** branch `feature/dm3-priming-authfix` at `955a4424` (work-stream DM-3 of
`docs/drive-mode-default-spec.md`), diffed against `main` at `ef78f31d`.
**Scope:** spec §0.2 (entire scope — priming card, `enterCruiseMode()` auth fix, denied-state
fallback, battery/render-posture guardrail), §0.1's no-nag constraint, AC-9 through AC-13, AC-14.
**Verdict: MERGE** — contingent on the Mac-gate live-UI smoke called out below (not completed in
this pass — no simulator access in this environment). No code fix required before merge; two
follow-up tickets recommended (see 🟡/🟢 findings), neither blocking.

## Summary

This is a clean, narrowly-scoped diff (4 files, 578 lines, zero file overlap with the other
in-flight DM streams) that does exactly what §0.2 asks: a one-shot `LocationPrimingCard` gated on
`.notDetermined` + flag-on + never-shown-before, and a real authorization-routing fix inside
`enterCruiseMode()` that closes a genuine pre-existing silent-dead-end bug. The gate shape, the
pure-function extraction pattern (for `nonisolated`/test reasons), the flag-off double-gating, and
the regression-guard tests for the already-authorized path are all correctly done and match this
codebase's established conventions. I found no functional defect that blocks merge. I did find one
real (if minor) UX gap relative to an existing in-codebase precedent, one gate-timing deviation from
the `BackgroundNoteGate` convention the PR claims to mirror exactly, and one zero-assertion test
padding the "12 tests" count. None of these are AC violations as literally written.

## Acceptance criteria checklist

- [x] **AC-9** (no prompt without a tap; one-shot card) — verified by code inspection +
  `LocationPrimingCardGateTests`/`LocationPrimingCardShouldShowTests` (8 tests). The card is
  double-gated: once at `performLaunchSetup()` (state computation) and again at
  `locationPrimingCardOverlay`'s render-time `if AppConstants.driveModeDefaultEnabled && ...`
  check. Nothing in the diff calls `requestWhenInUseAuthorization()`/`requestAndFetchLocation()`
  unconditionally on any launch path — the only two call sites added
  (`dismissLocationPrimingCard(allowed: true)`, `enterCruiseMode()`'s `.requestFirst` case) both
  require an explicit prior tap. Verified "dismissing at the system level doesn't re-show": once
  `markShown()` fires (on either button), `LocationPrimingCardGate.shouldShow()` returns `false`
  forever, confirmed cross-instance by `testTwoGateInstances_shareState_viaUserDefaults`.
- [x] **Gate shape matches `BackgroundNoteGate` byte-for-byte** — `LocationPrimingCardGate`
  (`Services/Constants.swift`) is structurally identical: injectable `UserDefaults` (default
  `.standard`), `shouldShow()`/`markShown()` pair, same doc-comment idiom. Verified by direct diff
  against `BackgroundNoteGate` in the same file. **Caveat:** the gate *struct* matches exactly; the
  *usage pattern* does not — see 🟢 Finding #2.
- [x] **AC-11 auth routing in `enterCruiseMode()`** — `.notDetermined` → `requestAndFetchLocation()`
  fires first, function returns, no escalation this tap (verified: the `switch` sits immediately
  after `guard noBlockingSheetPresented`, before any `driveModeStyle`/`driveModeActive` write).
  `.denied`/`.restricted` → `showLocationDeniedAlert = true`, a real `.alert` wired to
  `openLocationSettingsForCruiseEntry()` which calls `UIApplication.shared.open(URL(string:
  UIApplication.openSettingsURLString)!)` — a genuine working Settings deep link on a real button
  action, not just copy. `.authorized*` → falls through to `case .proceed: break`, then the
  **exact same four lines** (`driveModeStyle = .cruise`; `driveModeDistanceMeters = nil`;
  `driveModeActive = true`; comment) that existed before this diff — confirmed byte-identical via
  the unified diff (insertion is purely additive above the pre-existing body). Regression-guarded by
  `testAuthorized_routesToProceed_regressionGuard`.
- [x] **ToastService deviation claim verified true.** `ToastService.show(message:duration:)`
  (`Services/ToastService.swift`) takes only a string and a `TimeInterval` — no action-closure or
  button parameter, no way to attach a "tap to open Settings" affordance. The `.alert` choice is
  the only viable option in this codebase today for a button-bearing permission prompt. The new
  alert is a reasonable, slightly richer extension of `BrowseSearchAreaView`'s existing
  `showLocationDeniedAlert`/"Location Required" precedent (OK-only, no deep link) — same state
  name, same trigger shape (`.notDetermined`/`.denied`/`.restricted` switch mirrors
  `handleGoTap()`'s), genuinely adds the Settings deep link AC-11b explicitly asks for.
- [x] **AC-13 (biggest-risk invariant)** — grepped the full diff: zero touches to
  `driveModeActive`'s *semantics*, `startDriveMode()`, `LocationService.swift` (diff stat for that
  file is empty — confirmed untouched), or any wake-lock/continuous-GPS code. The only interaction
  with `driveModeActive` is the pre-existing `= true` assignment on the already-authorized path,
  now reached via `.proceed` instead of unconditionally — a gating change, not a semantic one.
- [x] **AC-2 family / flag-off byte-identical** — `locationPrimingCardOverlay` short-circuits to an
  empty `@ViewBuilder` body when `AppConstants.driveModeDefaultEnabled == false` (currently `false`
  on this branch, confirmed in `Constants.swift`), and `performLaunchSetup()`'s
  `locationPrimingCardShouldShow(...)` call independently also returns `false` when the flag is off
  — double-gated, redundant-but-safe. `testFlagOff_neverShows_evenWithFreshGateAndNotDetermined`
  covers this explicitly. The `enterCruiseMode()` auth fix is correctly flag-INDEPENDENT (its only
  call site today is `BrowseNavigationSheet`'s existing "Find a Spot" button, reachable flag-on or
  off per the pre-existing `noBlockingSheetPresented` doc comment) and changes behavior only in the
  `.notDetermined`/`.denied` branches — the `.authorized*` path is untouched, confirmed above.
- [~] **New overlay in the mount chain** — inspected, not live-smoked (see below). The overlay reuses
  the exact `VStack { content; Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)` idiom
  already shipped for `spotPlacementHintOverlay`, `confirmPromptOverlay`,
  `longPressParkConfirmOverlay`, `communityMapChromeOverlay`, and `parkingGuideBannerOverlay` in the
  same `ZStack` — no new positioning mechanism, no z-order change, and (confirmed by inspecting
  `parkingGuideBannerOverlay`) no spatial collision with the other first-launch card (that one is
  bottom-anchored via `Spacer()` then content; this one is top-anchored via `.padding(.top, 100)`
  then `Spacer()` — same convention `spotPlacementHintOverlay` already uses). **Not verified live** —
  see "Smoke tests run."
- [x] **AC-14 (tests/build hygiene)** — `grep -c "Calendar.current"` on the full diff: 0 matches.
  `Services/Constants.swift` imports only `Foundation`/`CoreLocation`, no `SwiftUI`.
  `LocationPrimingCard.swift` (a `Views/` file, correctly not a service) imports `SwiftUI` as
  expected. 12 named tests present across 3 groups (counted directly in
  `DM3PrimingAuthTests.swift`), covering AC-9 (8 tests: gate persistence + pure gating function) and
  AC-11 (4 tests: `cruiseEntryAuthAction` routing + regression guard). **AC-10 has no dedicated unit
  test** — see 🟢 Finding #3. `xcodebuild test` not run (no toolchain in this sandbox; file is
  explicitly `[COMPILE-UNVERIFIED]` per its own header, same disclosure convention used elsewhere in
  this codebase) — compile-failure-class static scan done instead (see below), no issues found.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant

- **#1: "Two-tap" auth-grant flow is a real UX gap, and the code comment mischaracterizes it as
  matching an existing precedent that actually auto-continues.**
  - Where: `ContentView.swift:3148-3156` (`enterCruiseMode()`'s `.requestFirst` case).
  - What: The comment says this uses "the same two-tap shape `BrowseSearchAreaView.handleGoTap()`
    already uses for destination-mode Drive's own `.notDetermined` branch." That's not accurate.
    `BrowseSearchAreaView.handleGoTap()`'s `.notDetermined` branch sets `isRequestingAuth = true`
    and calls `requestAndFetchLocation()`, but that view also has an
    `.onChange(of: locationService.isAuthorized) { ... if isRequestingAuth { ...
    Task { await fetchRouteAndReturn() } } }` handler that auto-continues into the actual action the
    instant the system prompt resolves — effectively a one-tap flow from the user's perspective.
    `enterCruiseMode()`'s new fix has no equivalent `.onChange` wiring; after the user taps "Allow"
    on the system dialog, nothing happens until they tap the ambient affordance again.
  - Expected: Either (a) the comment should not claim parity with a precedent it doesn't match, or
    (b) the actual behavior should match the precedent (auto-continue into Cruise once authorization
    resolves, mirroring `BrowseSearchAreaView`'s pattern).
  - Repro: Fresh install, flag on, tap ambient pill (once DM-2 lands) or `BrowseNavigationSheet`'s
    "Find a Spot" button (today, flag-independent) while `.notDetermined` → system prompt appears →
    tap "Allow" → prompt dismisses → nothing visibly happens → user must tap the same affordance a
    second time to actually enter Cruise.
  - Is this an AC violation? No — AC-11 only requires "routes through `requestAndFetchLocation()`
    first if `.notDetermined`... never silently does nothing," which is satisfied (the system prompt
    firing IS the visible response to the tap). This is a product/UX quality gap, not a spec breach,
    but it's exactly the flagship entry point this whole spec exists for, so it's worth fixing before
    or shortly after DM-2 wires the real ambient pill in.
  - Owner: `@ios-engineer` (fast-follow, can ride with DM-2 or its own small PR).

### 🟢 Minor / nit

- **#2: `LocationPrimingCardGate.markShown()` is called lazily (on explicit button tap), diverging
  from `BackgroundNoteGate`'s own usage pattern in this codebase (which marks shown eagerly, at the
  moment the decision-to-show is made — see `ContentView.swift:3619-3623`,
  `let gate = BackgroundNoteGate(); if gate.shouldShow() { gate.markShown(); showDriveModeBackgroundNote
  = true }`).** Practical effect: if a user sees the card but never taps either button (force-quits,
  or backgrounds while it's up), the gate stays unmarked and the card can reappear on a later launch.
  This isn't a bug — arguably a better UX (second chance) — but the PR's own doc comment claims
  "Byte-for-byte the same shape as `BackgroundNoteGate` ... deliberately, per DM-3's explicit
  instruction to follow that convention exactly." The *struct* is byte-for-byte identical; the
  *call-site timing convention* is not, and that divergence isn't flagged anywhere in the PR. Not
  tested (no test exercises "card shown, never interacted with, second launch"). Recommend either
  documenting this as an intentional, considered deviation, or adding a test for it.
  - Where: `ContentView.swift:3189-3196` (`dismissLocationPrimingCard`) vs. `:3619-3623`
    (`BackgroundNoteGate`'s usage).
  - Owner: `@ios-engineer` (doc-only fix, or a follow-up ticket; not merge-blocking).

- **#3: `testDocumentsUnknownDefaultBehavior()` has zero assertions.** It's transparently disclosed
  in its own doc comment ("no executable assertion... documents the intended behavior"), so this
  isn't deceptive, but it does mean the dispatch's "12 named tests" count includes one that verifies
  nothing. AC-10 ("Allow" fires `requestAndFetchLocation()`; "Not now" has zero side effects) is also
  not covered by any of the 12 — only verifiable by reading `dismissLocationPrimingCard`'s source,
  which the test file's own header explains is an architectural constraint (private instance method,
  not reachable from the test target even under `@testable import`). This is consistent with how
  `DriveModeDefaultFlagTests` handles the same constraint elsewhere in this codebase, so I'm not
  treating it as a gap unique to this PR — but it does mean AC-10's "Allow"/"Not now" button-wiring
  is unverified by anything except code inspection in this pass. Recommend covering both at the
  Mac-gate live smoke (tap "Allow," confirm the real system prompt appears; tap "Not now" on a fresh
  install, relaunch, confirm it does not reappear).
  - Where: `WeParkTests/DM3PrimingAuthTests.swift:240-243`.
  - Owner: `@ios-engineer` / `@qa-verifier` (Mac-gate smoke, not a code fix).

### 💡 Out of scope (logged, not fixed)

- This branch (`955a4424`, parent `bb47c5f1`) predates DM-2e's merge (`e3a89cc6`) and the designer's
  goal-first layout doc, both already on `main` (`ef78f31d`). DM-3 touches
  `ContentView.swift`/`Services/Constants.swift`/`Views/LocationPrimingCard.swift`/a new test file —
  zero file overlap with DM-2e's `ParkingRulesEngine.swift`/`Services/ParkingGoals.swift`/its own
  tests, so this should merge cleanly with no conflicts. Flagging only so whoever lands this rebases
  onto current `main` and re-runs the suite before merging rather than merging a stale base blind.

## Smoke tests run

- **Static diff review**: full `git diff main...FETCH_HEAD` read line-by-line for all 4 changed
  files (`ContentView.swift`, `Services/Constants.swift`, `Views/LocationPrimingCard.swift`,
  `WeParkTests/DM3PrimingAuthTests.swift`).
- **`Calendar.current` scan**: `git diff main...FETCH_HEAD | grep "Calendar.current"` → 0 matches.
- **Service-file `import SwiftUI` scan**: `Services/Constants.swift` imports only
  `Foundation`/`CoreLocation` — confirmed no SwiftUI import in a service file.
- **Six compile-failure-class static scan**: (1) contextual-type-on-literal-receiver — none found;
  (2) labeled-argument order — `locationPrimingCardShouldShow(driveModeDefaultEnabled:gateShouldShow:
  authorizationStatus:)` and `LocationPrimingCard(onAllow:onNotNow:)` call sites match declaration
  order exactly; (3) memberwise-init order — `LocationPrimingCard`'s synthesized init's call-site
  argument order matches property declaration order; (4) XCTestCase-extension name shadowing —
  grepped all existing `WeParkTests/*.swift` for the three new class names
  (`LocationPrimingCardGateTests`, `LocationPrimingCardShouldShowTests`,
  `CruiseEntryAuthActionTests`) — no collisions; (5) MainActor default isolation — both new
  top-level pure functions (`locationPrimingCardShouldShow`, `cruiseEntryAuthAction`) are correctly
  marked `nonisolated`, matching the precedent `driveModeDefaultRestStateSheet` set in DM-1; (6)
  ObjC-runtime name collision — no bare `Category`/`Protocol`/`Method`/`Ivar` usage in the diff.
- **`UIApplication` import risk check**: `ContentView.swift` has no explicit `import UIKit`, and this
  diff is the file's first use of `UIApplication`. Verified against precedent
  (`Views/NotificationRationaleView.swift`, which imports only `SwiftUI`/`UserNotifications` and
  already calls `UIApplication.shared.open(...)` successfully in the shipped app) that `import
  SwiftUI` transitively exposes `UIApplication` on iOS in this codebase — not a new compile risk.
  `CLAuthorizationStatus` similarly used without an explicit `import CoreLocation` in `ContentView.
  swift` — confirmed pre-existing precedent (`CLLocationCoordinate2D`/`CLLocation` already used
  throughout the file pre-this-diff without that import, via `import MapKit`'s transitive exposure).
- **`enterCruiseMode()` byte-identical regression trace**: diffed the function's pre/post body;
  confirmed the `.authorized*`/`.proceed` path reaches the exact same four statements
  (`driveModeStyle = .cruise`, `driveModeDistanceMeters = nil`, `driveModeActive = true`, the
  existing trailing comment) with no modification.
- **`LocationService.swift` untouched check**: `git diff main...FETCH_HEAD --stat -- .../LocationService.swift`
  → empty output, confirmed zero changes (AC-13's invariant).
- **Existing-test-regression-risk check**: grepped all of `WeParkTests/` for any existing test that
  calls `enterCruiseMode()`/`onCruiseTapped` directly — only comment references found
  (`FT15B2Tests.swift`, `FT20StreamCTests.swift`), no executable call sites that could break under
  the new auth-routing switch.
- **Gate-shape diff**: `LocationPrimingCardGate` vs. `BackgroundNoteGate` compared side-by-side in
  `Services/Constants.swift` — structurally identical (see AC checklist above).
- **ToastService capability check**: read `Services/ToastService.swift` in full — confirmed no
  action-button/closure parameter on `show(message:duration:)`, validating the PR's stated deviation
  rationale.
- **Overlay-stacking/position check**: read `parkingGuideBannerOverlay` and
  `spotPlacementHintOverlay` to confirm the new top-anchored card doesn't spatially collide with the
  other bottom-anchored first-launch banner.
- **NOT run — live-UI smoke.** No iOS simulator/Xcode toolchain available in this QA environment.
  Per this project's standing #31 mount-chain policy (any PR touching `ContentView.swift`'s overlay
  chain gets a mandatory screenshot-verified smoke before merge), this still needs to happen —
  **recommend at the Mac gate**: flag `driveModeDefaultEnabled = true` locally, fresh
  install/UserDefaults reset, confirm (a) the priming card renders exactly once and at the expected
  position (below the status bar/ASP banner, not colliding with other chrome), (b) "Allow" fires the
  real system dialog, (c) "Not now" dismisses and does not reappear on relaunch, (d) tap
  `BrowseNavigationSheet`'s existing "Find a Spot" button while `.denied` and confirm the new alert's
  "Open Settings" button actually opens the Settings app (not just dismisses). This QA pass is
  explicitly not signing off on that gate — it's a code-correctness + static-scan review only.

## What's working

- The pure-function extraction discipline (`locationPrimingCardShouldShow`,
  `cruiseEntryAuthAction`) is well-executed and directly testable, following the exact precedent
  `driveModeDefaultRestStateSheet` set in DM-1 for the same `nonisolated`/private-instance-method
  constraint. This made the AC-9/AC-11 logic genuinely unit-testable without a live `ContentView`.
- The regression-guard test (`testAuthorized_routesToProceed_regressionGuard`) is exactly the right
  shape — it directly protects the "zero behavior change for already-authorized users" promise,
  which is the single most important correctness property of this fix.
- Double-gating the priming card (both at state-computation time and render time) against the flag
  is slightly redundant but genuinely safer than relying on either alone — good defensive design
  given this file's regression history.
- The denied-state alert is a real, concrete improvement over the pre-existing
  `BrowseSearchAreaView` precedent (adds a working Settings deep link where the old one had none),
  and it's honestly scoped — no attempt to silently widen `enterCruiseMode()`'s escalation behavior.
- Doc comments throughout are unusually thorough and self-aware about trade-offs (the ToastService
  deviation is explained rather than hidden; the `[COMPILE-UNVERIFIED]` disclosure on the test file
  is honest about this environment's constraints) — this made cold review meaningfully faster.
