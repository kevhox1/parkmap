# Cruise Mode PR #38 QA Pass 1 — 2026-06-05

**Reviewed:** branch `ios/cruise-mode` at `e976b88`, against `docs/cruise-mode-spec.md` (AC-CM.1–19) and `docs/design/cruise-mode-button.md`
**Verdict:** PASS WITH NITS

## Summary

316/0 tests passing, RegionSyncGuardTests 2/2 pass. All acceptance criteria AC-CM.1–16 verified by code inspection. Live-UI smoke confirms the overlay chain is intact (map, ASP banner, gear button, 4 toolbar buttons including the single combined Menu drive entry, parking polylines). Two nit-level findings: (1) the `activeSheet == nil` guard that existed in the W8.5b destination button was dropped when the Menu replaced it, allowing theoretically concurrent sheet + drive-entry activation; (2) the design doc specifies an `accessibilityHint` on the Menu label that is absent. Neither is blocking for merge. The engineer's own verification report for the latest polish commit was noted as lost; this report serves as the primary QA pass.

---

## Acceptance criteria checklist

- [x] **AC-CM.1** "Find Parking" entry is visible on main map screen, not inside `DriveModeDestinationView`. Verified: `driveEntryButton` is a SwiftUI `Menu` in `recenterButtonStack` (ContentView.swift:1080–1101) with a "Find Parking nearby" item that calls `enterCruiseMode()` directly.
- [x] **AC-CM.2** Tapping "Find Parking" sets `driveModeActive = true`, `activeRoute = nil`, `driveDestinationCoordinate = nil`, `driveModeStyle = .cruise`. Verified: `enterCruiseMode()` (ContentView.swift:1198–1206) sets these exactly; `activeRoute` and `driveDestinationCoordinate` are never assigned.
- [x] **AC-CM.3** Destination mode entry continues to work. Verified: `showDriveModeDestination = true` is still wired in the Menu "Drive to a destination" item (ContentView.swift:1083); `onRouteReady` closure now sets `driveModeStyle = .destination` before `driveModeActive = true` (ContentView.swift:461–465).
- [x] **AC-CM.4** Camera transitions reuse `handleDriveCameraChange` — no second `.onChange(of: driveModeActive)` block. Verified: exactly one `.onChange(of: driveModeActive)` at ContentView.swift:848, which calls `handleDriveModeAndCamera` (line 1737–1740); no duplicate block added.
- [x] **AC-CM.5** `DriveModeBottomCard` visible in Cruise Mode with street name and L/R chips; distance indicator absent; approaching strip absent. Verified: card is shown whenever `driveModeActive` (ContentView.swift:959–966); `destinationDistance` is nil in Cruise Mode (never set); `showApproachStrip` requires `finalApproachState == .approaching` which never fires in Cruise Mode (AC-CM.12 guard).
- [x] **AC-CM.6** Parking overlay polylines visible at auto-zoomed span. Verified: `rebuildOverlays` path unchanged; overlays render when `span <= polylineHideSpanThreshold`; confirmed in live-UI smoke screenshot.
- [x] **AC-CM.7** Restricted/unknown blocks: voice silent. Verified: `DrivingContextService.update()` lines 248–255 — when `isCruiseMode` and `CruiseVoicePolicy.shouldAnnounce(context:)` returns false (both sides restricted or unknown), `speakContext` is not called. `testCruiseMode_restrictedBlock_doesNotSpeak` passes.
- [x] **AC-CM.8** Free block: voice speaks within 12s with "Free parking" lead. Verified: `CruiseVoicePolicy.utteranceText` produces "Free parking on the left/right/both sides." phrasing; `testCruiseMode_freeBlock_speaks` and `testCruiseMode_freeBlock_usesCruisePhrasing` pass.
- [x] **AC-CM.9** Metered block (no free side): voice speaks with metered phrasing. Verified: `CruiseVoicePolicy.utteranceText` metered branch (lines 127–135); `testUtteranceText_meteredOnlyNeitherFree_saysMetered` passes.
- [x] **AC-CM.10** 12s minimum gap enforced in Cruise Mode. Verified: `speakContext` guard (`now.timeIntervalSince(lastSpokenAt) >= voiceMinGapSeconds`) applies regardless of mode; `testCruiseMode_blockChange_respectsMinGap` passes.
- [x] **AC-CM.11** Mute toggle works in Cruise Mode; persists across sessions. Verified: mute toggle button shown in `driveModeOverlayLayer` when `driveModeStyle == .cruise` (ContentView.swift:1146–1158). Persistence confirmed: `DrivingVoice.isMuted` backed by `UserDefaults` key `wepark_dm_voice_muted` (DrivingVoice.swift:29, 62). Design doc note confirmed: mute persistence was NOT missing — the existing key is correct, no rename needed.
- [x] **AC-CM.12** `handleFinalApproachUpdate` NOT called in Cruise Mode. Verified: explicit `guard driveModeStyle == .destination else { ... return }` at ContentView.swift:1266–1271. `finalApproachState` stays `.outside`.
- [x] **AC-CM.13** `ActiveSheet.arrivalPrompt` NEVER presented in Cruise Mode. Verified: follows from AC-CM.12 guard — `newState == .arrived` block (line 1301) is unreachable when `driveModeStyle == .cruise` because `handleFinalApproachUpdate` returns early.
- [x] **AC-CM.14** `driveModeDistanceMeters` nil throughout Cruise Mode session. Verified: `updateDriveModeDistance` returns nil when `driveDestinationCoordinate == nil` (ContentView.swift:1235–1237); `driveDestinationCoordinate` is never set in `enterCruiseMode()`.
- [x] **AC-CM.15** Destination mode NOT regressed. Verified: (a) destination flow path unchanged; (b) `testDestinationMode_restrictedBlock_stillSpeaks` passes — destination mode still announces every block change; (c) W8.5d tests (`W85dTests`) still pass (included in the 316 count).
- [x] **AC-CM.16** `xcodebuild test` exits 0, 316 tests passing (≥315 required), 0 failures. No `Calendar.current` in new files. No `import SwiftUI` in service files. Verified: 316/0 confirmed; invariants confirmed by grep on CruiseVoicePolicy.swift and DrivingContextService.swift.
- [x] **AC-CM.17** Simulator screenshot before Drive Mode entry: gear button, find-me, find-my-car, clock, single combined drive-entry — all visible. ASP banner present. Verified: `/tmp/qa-cruise-smoke-5-pr38.png` (Jun 5 PR #38 build) shows green "ASP in Effect Today" banner, gear button top-left, 4 toolbar buttons top-right, parking polylines on CHRYSTIE ST. Single drive-arrow icon visible (not two buttons). Overlay chain intact — no #31-class regression.
- [ ] **AC-CM.18** Simulator screenshot after Cruise Mode entry shows bottom card + End Cruise pill + toolbar hidden. NOT VERIFIED via screenshot — native SwiftUI `Menu` cannot be driven headlessly via `xcrun simctl` (no tap injection). Verified by code inspection: `driveModeActive = true` causes `driveModeOverlayLayer` to render (ContentView.swift:829), `DriveModeBottomCard` to render (line 959–966), and `recenterButtonStack`'s drive button to show the static blue tinted icon (line 1053–1065). Functionally correct by code review; live validation requires Kevin's manual tap.
- [ ] **AC-CM.19** Kevin's manual smoke: Cruise Mode entry from one tap; map tilts/zooms; voice announces "Free parking on [side]"; silent on restricted blocks; "End Cruise" exits cleanly. NOT VERIFIED — requires Kevin's manual in-app test. Cannot be satisfied by any automated tooling.

---

## Findings

### Significant
*(None)*

### Minor

**#1: `activeSheet == nil` guard dropped from drive-entry button**
- Where: `ContentView.swift:1080–1101` (`driveEntryButton` Menu)
- What: The W8.5b destination-mode Button had an explicit `guard activeSheet == nil else { return }` (confirmed in main branch ContentView.swift:982–984). The replacement Menu has no such guard. Both `showDriveModeDestination = true` and `enterCruiseMode()` can now be triggered while a sheet (e.g., `ParkConfirmView`, `BlockDetailView`, `ParkUntilSheet`) is open. SwiftUI's `fullScreenCover` + `.sheet(item:)` do not automatically dismiss the existing sheet when a new one is requested from within a Menu action.
- Expected: Per spec §5.1 — "Guard: same as destination mode entry — `guard activeSheet == nil else { return }` before activating."
- Repro: Open ParkConfirmView (long-press map). While the sheet is open, tap the drive-entry toolbar button. The Menu appears. Tap "Find Parking nearby." Drive Mode activates with the sheet still shown.
- Owner: `@ios-engineer`

### Nit

**#2: Missing `accessibilityHint` on combined drive-entry Menu label**
- Where: `ContentView.swift:1100` (`driveEntryButton`)
- What: Implementation has `.accessibilityLabel("Start Drive Mode")` but no `.accessibilityHint(...)`. The design doc (`docs/design/cruise-mode-button.md`) specifies: `.accessibilityHint("Double-tap to choose destination navigation or find parking nearby.")`.
- Expected: Hint present per design doc.
- Owner: `@ios-engineer`

---

## Diff scope

Files changed vs `main`:
- `docs/design/cruise-mode-button.md` — design decision note (expected)
- `ios/WePark/WePark/Services/CruiseVoicePolicy.swift` — new (expected)
- `ios/WePark/WePark/Services/DrivingContextService.swift` — modified (expected)
- `ios/WePark/WePark/ContentView.swift` — modified (expected)
- `ios/WePark/WePark/Views/DriveModeBottomCard.swift` — modified (expected)
- `ios/WePark/WeParkTests/CruiseVoicePolicyTests.swift` — new (expected)
- `ios/WePark/WeParkTests/DrivingContextServiceCruiseModeTests.swift` — new (expected)

**No unexpected files.** `MapViewRepresentable.swift` not touched (correct per spec §6.3). `FinalApproachService.swift`, `ArrivalPromptSheet.swift`, `RouteService.swift`, `DriveModeDestinationView.swift`, `project.pbxproj`, `Info.plist`, `Config.xcconfig*` all untouched.

---

## Smoke tests run

1. **Build** — `xcodebuild build` against worktree project, iPhone 17 Pro simulator (F0820726-15F4-4FA3-8602-A5D7B479A277, iOS 26.4). Exit 0, no errors, no warnings.
2. **Full test suite** — `xcodebuild test` against same simulator. **316 passed, 0 failed.** Output at `/tmp/qa-test-out.txt`.
3. **RegionSyncGuardTests** — `testRegionSync_driveModeActive_returnsFalse` and `testRegionSync_driveModeInactive_returnsTrue` both passed. PR-3 architecture fix preserved.
4. **CruiseVoicePolicyTests (11 tests)** — All 11 passed. Decision table fully covered (7 `shouldAnnounce` cases + 3 `utteranceText` phrasing cases + 1 `minimumGapSeconds` constant check). Tests assert decoded behavior, not stubs.
5. **DrivingContextServiceCruiseModeTests (5 tests)** — All 5 passed. Covers: restricted block silent, free block speaks, free block uses Cruise phrasing, destination mode unchanged, min-gap enforced.
6. **Secrets scan** — `grep -r "pk.eyJ" --exclude-dir=.git ios/` = zero results. No tokens committed.
7. **Live-UI smoke (collapsed toolbar state)** — PR #38 build (Jun 5 09:28, DerivedData `WePark-cmfcpjszrrvvhpfufwjjzijcpvos`) installed and launched on booted simulator. Screenshot `/tmp/qa-cruise-smoke-5-pr38.png` confirmed:
   - Green "ASP in Effect Today" banner at top — intact
   - Gear button top-left — intact
   - 4 toolbar buttons top-right: location (blue arrow), car, clock, single drive-arrow icon — intact, exactly 4, no doubling
   - Parking polylines (green) rendering along CHRYSTIE ST at street-level zoom
   - No blank screen, no missing overlay layers — #31-class regression is NOT present
   - Main branch smoke (`/tmp/qa-cruise-smoke-main.png`) shows identical layout as baseline, confirming visual parity
8. **Live-UI smoke (Cruise Mode active state)** — NOT ACHIEVABLE via `xcrun simctl` (no tap injection for SwiftUI Menu). Verified by code inspection: `driveModeActive = true` causes `driveModeOverlayLayer` + `DriveModeBottomCard` to render, toolbar drive button shows static blue tinted icon. Kevin's manual tap required to confirm AC-CM.18 and AC-CM.19.

**Note on earlier blank screenshots:** Smoke screenshots 1–4 showed blank white/black screens. Root cause: the simulator was in an unstable booted-then-shutdown state, and the install/launch cycle was racing against it. The final smoke (screenshot 5) was taken after a clean boot + clean install, confirmed by checking the installed binary modification date (Jun 5 = PR #38 build) and comparing visually against the main branch smoke.

---

## What's working

- **Architecture is sound.** `DriveModeStyle` enum is a clean, grep-auditable gate. Exactly one `.onChange(of: driveModeActive)` block (the existing `handleDriveModeAndCamera`). `handleFinalApproachUpdate` correctly guards on `driveModeStyle == .destination`. No mutation inside `updateUIView`.
- **`CruiseVoicePolicy` mirrors the spec pattern exactly.** Pure static enum, no framework imports, no `Calendar.current`, no `import SwiftUI`. Decision table matches spec §4.2 verbatim. The "Free parking on the left/right/both" phrasing is correctly affirmative-lead.
- **Destination mode regression-free.** `testDestinationMode_restrictedBlock_stillSpeaks` confirms the pre-CM-2 unconditional-announce behavior is preserved. The 243 pre-existing tests (W8.5d baseline) all still pass.
- **Patrol mode reserved.** `DriveModeStyle.patrol` case declared per spec §8 convergence contract. Future patrol mode engineer can extend without re-architecting.
- **Mute touch target correct.** `DriveModeBottomCard` mute button now uses a 44×44pt `frame` + `.contentShape(Rectangle())` wrapping the 36pt visual circle. HIG minimum satisfied.
- **Native SwiftUI Menu is correct implementation.** Not custom pills, not long-press, not two separate toolbar buttons. System-managed presentation, automatic dismiss on outside tap, system-sized (labels cannot truncate), accessibility provided natively for item labels.
- **Design doc compliance.** Button labels "Drive to a destination" and "Find Parking nearby" match design doc exactly. SF Symbols `arrow.triangle.turn.up.right.diamond` and `car.front.waves.right.fill` used as specified.
- **Test quality is real.** `CruiseVoicePolicyTests` tests assert actual output strings ("Free parking on the left.", "Metered on both sides."), not just non-nil return values. `DrivingContextServiceCruiseModeTests` exercise live `DrivingContextService` with `MockDrivingVoice` call counts.
