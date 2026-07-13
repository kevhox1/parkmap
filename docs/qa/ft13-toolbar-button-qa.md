# FT-13 Parking 101 Toolbar Button — QA Pass 1 — 2026-07-13

**Reviewed:** PR #67, branch `ios/ft13-guide-toolbar-button` at `eeabc28`, against `docs/field-testing-log.md` FT-13 entry (no dedicated spec doc — single-file toolbar tweak per TEAM.md sizing rule).
**Verdict:** ✅ ship it

## Summary

FT-13 adds a second 44×44 toolbar button ("?" / `questionmark.circle`) immediately to the right of the existing gear button, wired to the already-shipped `ActiveSheet.parkingGuide` sheet (FT-12), and hidden during Drive Mode via a new pure `parkingGuideButtonVisible(driveModeActive:)` function. The diff is minimal (`ContentView.swift` + a new `FT13Tests.swift`, +100/-7 lines total), matches the FT-13 log entry's scope exactly, and the button anatomy mirrors the existing gear button (same size, same `.regularMaterial` background, same `.secondary` tint) per the TF2-18 standardized pattern. Live-UI smoke confirms both buttons render correctly side-by-side with no layout collision against the ASP banner. One pre-existing, unrelated test-suite flake (`CommunityPinServiceRequestTests`) surfaced during verification and is documented below as an infra finding, not a code defect in this PR.

## Acceptance criteria checklist

(No formal AC list exists for this single-file PR — scope per the FT-13 field-testing-log entry, checked against that.)

- [x] Button added to existing map toolbar (not a new overlay layer) — verified: `gearButtonOverlay`'s existing `VStack`/`HStack` is extended in place, no new `.safeAreaInset` or `.overlay` chain introduced.
- [x] Wires to `activeSheet = .parkingGuide` (case exists since FT-12, not reintroduced) — verified in diff; `FT13ToolbarWiringTests.testParkingGuideSheetCase_stillHasStableID()` guards the case's stable `id`.
- [x] Follows TF2-18 button anatomy (44×44, `.regularMaterial` RoundedRectangle, `.secondary` tint, accessibility label) — verified by direct code comparison to the gear button, and visually confirmed in the live-UI screenshot.
- [x] Reachable "all the time" per Kevin's request, not gated behind the FT-12 first-launch banner — verified: button lives in the always-mounted `gearButtonOverlay`, independent of the FT-12 banner's one-shot `BackgroundNoteGate`-style state.
- [x] Doesn't collide with Drive Mode's top-left overlay (End Drive / Report / Park Here pill row) — verified via `parkingGuideButtonVisible(driveModeActive:)` returning `false` when driving, unit-tested for both states.

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

None specific to this PR's code.

### 🟢 Minor / nit

- **#1: Second consecutive PR with no dedicated spec doc**
  - Where: n/a (process observation)
  - What: FT-13, like some recent small field-testing items, was dispatched straight from the `field-testing-log.md` entry without a `docs/ft13-*.md` spec. That's explicitly authorized here ("No spec needed (single-file tweak per TEAM.md sizing)"), and the scope was indeed tiny and unambiguous, so this isn't a process violation — just noting for the record that the QA "acceptance criteria" above are QA-derived from the log entry, not spec-derived.
  - Expected: n/a, informational only.

### 💡 Out of scope (logged, not fixed)

- **CommunityPinServiceRequestTests flakiness is an environment issue, not a code defect.** Full-suite `xcodebuild test` runs intermittently failed/hung on `CommunityPinServiceRequestTests` (unrelated file — `CommunityPinServiceTests.swift`, not touched by this diff) with wildly inflated per-test durations (up to ~1984s) and repeated `IDETestOperationsObserverDebug: Failure collecting diagnostics... Timed out after 600.0 seconds` / `DTDKRemoteDeviceConnection ... "The device is passcode protected."` errors in the log. `xctrace list devices` on this Mac shows a paired, passcode-locked physical iPhone (`iPhone (26.6) (00008130-0012444010A1401C)`) listed under "Devices Offline" — Xcode's diagnostics collector appears to be trying (and repeatedly timing out) to reach that locked device during every simulator test run, not anything in `CommunityPinService`'s request-building logic. Confirms as environmental, not code, because: (a) the diff doesn't touch `CommunityPinService.swift` or its tests at all; (b) the same suite passed cleanly on one retry within the same `xcodebuild` invocation with zero code changes between attempts; (c) the two FT-13-specific test classes (`FT13ToolbarWiringTests`, `ParkingGuideButtonVisibilityTests`) passed 100% of the time across all three full-suite attempts. Recommend disconnecting/unlocking the paired physical device (or removing the pairing) before the next full-suite CI-style run on this machine — this is slowing every test invocation, not just this PR's.

## Smoke tests run

- **Diff read** — `git diff main...HEAD` on the worktree: 2 files changed (`ContentView.swift`, `WeParkTests/FT13Tests.swift`), +100/-7. Read in full, adversarially, for stray overlay-layer changes, z-order regressions, and accessibility gaps — none found.
- **Targeted unit tests** — `ParkingGuideButtonVisibilityTests` (2 tests) and `FT13ToolbarWiringTests` (1 test) passed on every one of 3 separate full-suite `xcodebuild test` invocations against the `qa-ft13` simulator (`6E6EA203-...`), 0 failures, 0 flakes.
- **Full suite** — ran 3 times total (~800+ individual test cases per run based on suite list observed: FT8Zoom, PinAxisEnum, CommunityPinGracefulFallback, ReportSheetLocationContextLabel, FT11Segment/AutoDerive/HeadingToward/BuildMeta, W7ParkedCarCodable, OptionA*, SafetyLabelSideOpportunity, EndDrivePillZOrder, FT1MobilePinTTL, BuildUtteranceTextTF27, ReportSheetEnabled, ParkingGuide*, FT13Toolbar, and more). Every suite unrelated to `CommunityPinServiceRequestTests` passed cleanly and consistently across all 3 runs. `CommunityPinServiceRequestTests` flaked (see Out-of-scope finding above) — traced to a paired locked physical device on the QA machine, not the code under review.
- **Live-UI smoke (mount-chain gate, mandatory for `ContentView.swift` PRs)** — built + installed + launched on simulator `qa-ft13`, `xcrun simctl io ... screenshot` captured to `ft13_smoke.png`, and inspected via the `Read` tool (multimodal). **Confirmed**: gear button (blue gearshape icon) and new "?" button (blue circled question mark) render side-by-side at the top-left, both correctly sized against the existing recenter-button cluster on the right, both on `.regularMaterial` rounded-rect backgrounds, no visual overlap or clipping. ASP banner ("ASP in Effect Today", yellow) renders correctly at the top and does not collide with the button row below it. This satisfies the HANDOFF.md hard gate for PRs touching `ContentView.swift`'s overlay chain — the W8.5c-polish regression class (toolbar silently missing despite 210/0 passing tests) is not present here.
- **Cross-reference to FT-12** — confirmed `ActiveSheet.parkingGuide` case and its sheet content were not touched or duplicated by this PR; FT-13 is purely a second trigger point for the existing FT-12 sheet infrastructure. `ParkingGuideActiveSheetTests` (FT-12's own coverage) still passes.
- **HANDOFF.md invariant check** — no Supabase/RLS surface touched (pure client-side UI), no Service Worker involved (this is the iOS app), no new SPM packages, `project.pbxproj`/`Info.plist`/`Config.xcconfig*` not touched. No invariant violations.

## What's working

- Scope discipline: exactly what the field-testing-log entry asked for, nothing more — no scope creep into the FT-12 sheet content itself.
- Visibility-gating logic extracted as a pure, trivially-testable function (`parkingGuideButtonVisible`) rather than inlined into the view body, consistent with the established `paddingForBannerState` / `recenterPillBottomPadding` pattern in this codebase — good adherence to house style.
- The engineer correctly anticipated and pre-empted the Drive Mode top-left occlusion issue (documented in code comments referencing `driveModeOverlayLayer`) rather than leaving a stray tappable button behind the drive pill row, which is exactly the kind of z-order bug this codebase has a documented history of (#31 regression class).
- Live-UI smoke is clean on the first screenshot — no re-shoot needed.
