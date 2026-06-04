# Cruise Mode — Route-less Drive Mode

**Status:** Spec draft 2026-06-04. Waiting on Kevin's answers to §0 open questions before code starts.
**Author:** @tech-lead
**Date:** 2026-06-04
**Depends on:** W8.5d merged (PR #35, `3685006`) — destination-mode Drive Mode is feature-complete on main.
**Blocks:** Patrol mode sub-PR #2 (`tier3-patrol-mode-buildplan.md` §2) — patrol mode's UI surface and follow-camera are Cruise Mode consumers. Read §8 (Convergence with Patrol Mode) before starting either.
**Related:**
- `docs/drive-mode-scope-spec.md` §2 (AC-DM.5 already contemplates destination-less operation — this spec makes it a first-class mode, not a fallback edge case)
- `docs/w8.5c-drive-mode-active-spec.md` — the commentary engine, heading-up, follow-mode, voice (all reused without change)
- `docs/w8.5c-polish-pr2-spec.md` — auto-zoom, `.mutedStandard` style, directional puck (all reused without change)
- `docs/w8.5d-final-approach-spec.md` + `ios/WePark/WePark/Services/FinalApproachService.swift` — the pure-function `voiceGap` pattern that Cruise Mode's `CruiseVoicePolicy` directly generalizes
- `docs/tier3-patrol-mode-buildplan.md` §2 — patrol mode sub-PR #2 reuses this spec's camera/mode-state layer; do not double-build

---

## §0 — Open Questions for Kevin — Surface These First

| # | Question | Options | Recommendation |
|---|---|---|---|
| OQ-1 | **User-facing name: "Cruise Mode" vs. "Find Parking" vs. something else?** | (a) "Cruise Mode" — evocative, novel, consistent with the internal spec name. (b) "Find Parking" — descriptive, maps directly to the user's intent. (c) "Nearby Parking" — softer, less imperative. | **(b) "Find Parking."** It's the most literal expression of the user's intent. The entry button can say "Find Parking" while the active state banner says "Finding Parking…" A driver who has never used the app knows exactly what it does. "Cruise Mode" is a good internal codename but is too opaque for a button label. |
| OQ-2 | **Voice cadence specifics: only-when-free vs. all-blocks?** | (a) Announce every block, regardless of status (mirrors destination-mode behavior: "Right side, no parking. Left side, no parking."). (b) Announce only when a free or metered block is on either side — stay silent on all-restricted blocks. Rationale: if both sides of a block are restricted, announcing it adds noise without value for the user trying to find a spot. | **(b) Announce only when at least one side is free or metered.** All-restricted blocks are common on NYC avenues; announcing them while the driver circles adds noise that undermines trust in the system. The `CruiseVoicePolicy.shouldAnnounce` pure function gates on at least one side having severity `.free` or `.metered`. See §4 for the full policy definition. |
| OQ-3 | **Exit → Park-Until hook: should "End Cruise" auto-fire the W7.5 Park Until sheet (like W8.5d's arrival-confirm path does)?** | (a) Yes — tap "End Cruise" automatically fires the Park Until sheet, on the assumption that ending a parking search means the user found a spot. (b) No — "End Cruise" just ends the mode. The user can long-press or tap "Park here →" on their own. Rationale for (b): "End Cruise" can mean "I'm giving up," not just "I found a spot." Indiscriminate auto-fire would be annoying in the giving-up case. | **(b) No auto-fire on "End Cruise."** Reserve auto-fire for explicit intent signals — the W7.5 departure from that rule was for W8.5d's arrival-confirm path (the user has just tapped "Park Here"), which is an unambiguous found-a-spot signal. "End Cruise" is ambiguous. The user can long-press to drop a pin manually (W5 flow). |
| OQ-4 | **TestFlight placement: TF1 (same cut as destination-mode Drive Mode) or TF2?** | (a) TF1 — ships with the rest of Drive Mode since it is a subtractive simplification, not an additive feature. Build cost is 1–2 sessions. (b) TF2 — defer until the destination-mode drive-test has returned calibration feedback, then add Cruise Mode in a TF2 patch. | **(a) TF1.** Cruise Mode's build delta is small (1–2 sessions). It fills a real user need: someone who is already near their destination or just circling does not need to type an address. Shipping a Drive Mode with destination-only entry in TF1 would immediately generate feedback from users who want to start driving without entering an address. Better to ship it complete. |
| OQ-5 | **One PR or two?** | (a) Single PR — the routing-guard layer + the "Find Parking" entry point + the `CruiseVoicePolicy` engine + tests + live-UI smoke, all in one. (b) Two PRs — PR-1: routing guard + entry point (no behavioral change to voice, just the entry seam and the mode distinction); PR-2: `CruiseVoicePolicy` + voice gating (the novel piece). | **(a) Single PR.** The guard layer and the policy are tightly coupled — you cannot ship the entry without the policy or you ship a mode that announces every block (wrong UX). A single PR with a clean `CruiseModeVoicePolicy` test file is reviewable in one pass. Two PRs would require a PR-1 that enters the mode with destination-mode voice behavior as an interim state — confusing for QA. |

---

## §1 — Problem and User Story

**The moment this solves:** A driver has just arrived in the general vicinity of their destination — say they've parked at Penn Station before, so they know the blocks near 34th and 8th. They do not want to type an address. They want to circle the block, hear what parking is available, and find a legal free spot. Today's Drive Mode requires a destination input before activating. This is friction that the most common seasoned NYC parker does not need.

**The insight (verbatim from Kevin):** "I'm already in the area, help me find a legal/free spot while I circle the block." This is destination-LESS. The camera, the overlays, and the voice are all present in destination-mode Drive Mode. The only things missing are (1) a route-less entry path, and (2) a voice cadence tuned for searching-not-arriving.

**User story:**
> As a driver who is already near my target neighborhood, I want to tap "Find Parking" on the WePark map without entering an address, so the map follows my heading and tells me which blocks have free or metered parking as I circle, without routing me anywhere specific.

**Why now:** Destination-mode Drive Mode (W8.5a–d) is complete and on main. Cruise Mode is subtractive: it reuses the entire active-layer stack and removes the route-dependent branches. The delta is a mode flag, an entry button, and a voice-cadence policy. The patrol mode build (tier3-patrol-mode-buildplan.md sub-PR #2) needs this camera/mode-state layer as its foundation — shipping Cruise Mode first prevents patrol mode from needing to re-implement it.

---

## §2 — Scope

### 2.1 In scope

1. **`DriveMode` distinction: `.destination` vs. `.cruise`.** A new `enum DriveMode { case destination; case cruise }` (or equivalent gate on `activeRoute == nil`) that cleanly gates every route-dependent behavior from the shared camera/overlay/voice stack.
2. **"Find Parking" entry point.** A second Drive Mode entry button (or a modified version of the existing Drive button) that activates Drive Mode without opening `DriveModeDestinationView`. Sets `driveModeActive = true` with `activeRoute = nil` and `driveDestinationCoordinate = nil`.
3. **Route-dependent behavior gating.** An explicit list of code paths that are guarded `guard driveMode == .destination else { return }` (or nil-checked on `activeRoute`):
   - Route polyline rendering (already nil-guarded by `activeRoute` — no change needed)
   - Destination pin annotation (already nil-guarded by `driveDestinationCoordinate` — no change needed)
   - `handleFinalApproachUpdate` and all of `FinalApproachService` logic (guarded by `driveMode == .destination` — new guard)
   - Arrival prompt (`ActiveSheet.arrivalPrompt`) — already guarded by `finalApproachState == .arrived`, which can never be reached without a destination; confirm this guard is sufficient or add an explicit `driveMode == .destination` check
   - `driveModeDistanceMeters` computation — set to nil when `driveMode == .cruise`
   - Distance-to-destination indicator on `DriveModeBottomCard` — hidden when `destinationDistance == nil` (already conditional — no change)
4. **`CruiseVoicePolicy` — pure-function voice cadence.** New type at `Services/CruiseVoicePolicy.swift`. Governs which blocks get announced in Cruise Mode and the minimum gap between callouts. Full spec in §4.
5. **`DrivingContextService` mode-awareness.** A new `setCruiseMode(_ isCruise: Bool)` method (or equivalent) that routes the per-block decision through `CruiseVoicePolicy.shouldAnnounce` when cruise is active, bypassing the unconditional speak-on-block-change behavior in destination mode.
6. **"End Cruise" exit.** The existing "End Drive" pill exits Cruise Mode cleanly. `endDriveMode()` is called. `activeRoute` and `driveDestinationCoordinate` remain nil (they were nil in Cruise Mode). No Park-Until auto-fire (OQ-3).
7. **Mandatory live-UI smoke gate.** This PR touches `ContentView.swift`, `MapViewRepresentable.swift` (indirectly, via `driveModeActive` binding), and `DriveModeBottomCard.swift`. The toolbar layer / ASP banner / Park-Until pill regression check is mandatory. See §6.

### 2.2 Out of scope (explicitly deferred)

- **Sweep routing / `PatrolModeService`.** Cruise Mode is free-roam (user drives where they want). The guided sweep (greedy graph traversal, `generateParkingRoute` port) is patrol mode's job (`tier3-patrol-mode-buildplan.md` sub-PR #2). Cruise Mode does not compute routes.
- **"Near-block" look-ahead voice cues.** Announcing what is "1 block ahead" on the driver's current heading would require lookahead geometry. Out of scope for this cut — voice announces the block the driver is currently on, same as destination-mode.
- **Driver-side filtering ("only show free blocks").** The overlay coloring is the existing palette; no separate filter for Cruise Mode. Park Until X filter (W7.5) continues to apply to the map colors and is orthogonal to Cruise Mode entry.
- **Exit → Park-Until hook.** OQ-3 resolved no — no auto-fire on "End Cruise."
- **Patrol mode reporting flow.** Long-press to report community pins while in a cruise-like state is patrol mode sub-PR #2 scope, not Cruise Mode scope.
- **Voice calibration constants.** `CruiseVoicePolicy.minimumGapSeconds` ships at 12 seconds (baseline). Post-drive-test tuning is W8.5c-follow, same as destination-mode calibration.
- **Re-routing on deviation.** Not relevant to Cruise Mode — there is no route to deviate from.

---

## §3 — Route-Less Active State (the key design problem)

### 3.1 The mode distinction

The cleanest gate is `activeRoute: DriveRoute?`. When `activeRoute == nil` and `driveModeActive == true`, the app is in Cruise Mode. When `activeRoute != nil`, it is in Destination Mode. This avoids a separate `driveMode` enum entirely — the existing nil state already implies route-less operation.

However, this nil-based gate is implicit and has caused bugs before (the W8.5c `driveHeading == nil` guard inversion that the PR-3 QA caught). For the voice-cadence change — where Cruise Mode behavior must be deliberately different from Destination Mode behavior — a named, explicit gate is safer. **Recommendation: add `var driveModeStyle: DriveModeStyle` to `ContentView` state, where `enum DriveModeStyle { case destination; case cruise; case inactive }`.** The style is set at the Drive Mode entry point and checked in `DrivingContextService` and `ContentView`'s final-approach handlers.

This is a three-line state addition and makes the routing-gate logic auditable by grep.

### 3.2 What is gated by `driveModeStyle == .destination`

| Code path | File | Current gate | Change needed |
|---|---|---|---|
| `handleFinalApproachUpdate` firing | `ContentView.swift` | Called from `.onChange(of: driveModeDistanceMeters)` | Guard: `guard driveModeStyle == .destination else { return }` — add to the `.onChange` handler |
| `driveModeDistanceMeters` update | `ContentView.swift` | Computed on every location fix when `driveModeActive` | Guard: only compute when `driveDestinationCoordinate != nil` (already implicitly true since `CLLocation.distance` from nil would require nil-check; verify this is already guarded in the existing code) |
| `FinalApproachService` calls | `ContentView.swift` | None — called from `handleFinalApproachUpdate` | Follows from the `handleFinalApproachUpdate` guard above |
| `ActiveSheet.arrivalPrompt` | `ContentView.swift` | Gated on `!arrivalPromptFired && finalApproachState == .arrived` | `finalApproachState` never transitions from `.outside` in Cruise Mode (because `handleFinalApproachUpdate` is gated) — no arrival prompt is possible. Belt-and-suspenders: also check `driveModeStyle == .destination` in the arrival fire condition |
| Distance indicator on bottom card | `DriveModeBottomCard.swift` | `destinationDistance == nil` → hidden (already conditional) | No change needed — `destinationDistance` is nil in Cruise Mode |
| Route polyline | `MapViewRepresentable.swift` | `activeRoute == nil` → no polyline (already conditional) | No change needed |
| Destination pin | `MapViewRepresentable.swift` | `driveDestinationCoordinate == nil` → no pin (already conditional) | No change needed |

**Camera, overlays, and voice engine are NOT gated** — they run identically in both modes. The heading-up rotation, auto-zoom, `.mutedStandard` style, directional puck, `DrivingContextService.update()`, `DrivingVoice.speak()`, and `DriveModeBottomCard` render unchanged. This is the spec's central claim: Cruise Mode is subtractive.

### 3.3 `DrivingContextService` mode-awareness

`DrivingContextService` currently calls `speakContext(_:)` unconditionally on every block change (line 197–200 of `DrivingContextService.swift`). In Cruise Mode, we want `CruiseVoicePolicy.shouldAnnounce` to gate that call. The change is minimal:

Introduce `func setCruiseMode(_ isCruise: Bool)` on `DrivingContextService`. When `isCruise == true`, the `speakContext` call in `update(...)` passes through `CruiseVoicePolicy.shouldAnnounce(context:)` before speaking. When `isCruise == false` (destination mode), the existing unconditional behavior is preserved — no regression.

This is a ~5-line change to `DrivingContextService.swift`. It does NOT change `voiceMinGapSeconds` logic — that remains driven by `FinalApproachService` in destination mode and uses the baseline 12-second gap in Cruise Mode (cruise never enters `.approaching` or `.arrived` states).

---

## §4 — Voice Cadence Policy (the crux)

### 4.1 Design rationale

In destination-mode, voice announces every block change because every block is relevant context on the way to a known goal. In Cruise Mode, the driver is searching. Announcing "No parking. No parking. No parking." on three consecutive avenue segments is noise that erodes trust in the system. The policy should speak only when the announcement helps the driver act.

The `FinalApproachService` pattern (pure static functions, no framework dependencies, exhaustive switch, unit-testable at zero cost) is the direct model. `CruiseVoicePolicy` mirrors that pattern exactly.

### 4.2 `CruiseVoicePolicy` — full specification

**File:** `ios/WePark/WePark/Services/CruiseVoicePolicy.swift`
**Pattern:** `enum CruiseVoicePolicy` with all-static methods, no instance state, no framework imports. Directly mirrors `FinalApproachService.swift`.

**`shouldAnnounce(context: DrivingContext) -> Bool`**

Gate conditions (ALL must be true to announce):

1. **At least one side is actionable.** Either `context.leftLabel.severity == .free` OR `context.rightLabel.severity == .free` OR either side is `.metered`. Rationale: restricted-only and unknown-only blocks offer no parking opportunity; announcing them wastes voice budget.
2. **Not "No data" on both sides.** If both labels are `.unknown`, the driver is in a coverage gap — silence is correct.

Decision table:

| Left severity | Right severity | Announce? |
|---|---|---|
| `.free` | any | YES |
| any | `.free` | YES |
| `.metered` | any | YES |
| any | `.metered` | YES |
| `.restricted` | `.restricted` | NO |
| `.restricted` | `.unknown` | NO |
| `.unknown` | `.restricted` | NO |
| `.unknown` | `.unknown` | NO |

**`minimumGapSeconds: TimeInterval`**

Static constant: `12.0`. Same as `FinalApproachService.baselineVoiceGapSeconds`. Calibration deferred to W8.5c-follow post-drive-test.

**`utteranceText(for context: DrivingContext) -> String`**

Cruise Mode voice phrasing is a minor variant of destination-mode's `DrivingContextService.buildUtteranceText`. In Cruise Mode, the free-block is the headline:
- If free on one side: "[StreetName]. Free parking on [Left/Right]." (omit the other side's label if restricted — restricted is already the driver's fear, not the action item)
- If free on both sides: "[StreetName]. Free parking on both sides."
- If metered on one or both sides with no free: "[StreetName]. Metered on [Left / Right / both sides]."
- The "No data" clause is omitted (same as destination mode).

Rationale: in Cruise Mode the driver wants to know "can I park there?" immediately. The affirmative lead ("Free parking on left") is more actionable from a dashboard-mount than the neutral format ("[Street]. Left side, free until..."). The full "until when" restriction text is still shown on the visual chips in `DriveModeBottomCard` — voice in Cruise Mode is the action cue, not the full data read-out.

**De-duplication:** `DrivingContextService`'s existing `lastBlockKey` guard already prevents re-announcing the same block. No additional de-dup needed. The driver must move to a new block before the next announcement fires. If the driver circles back to a previously-announced block, it will re-announce (correct behavior — the time has changed, the context may have changed).

### 4.3 Integration with `DrivingContextService`

In `DrivingContextService.update(...)`, the existing block-change path (lines 197–200):

```swift
if blockKey != lastBlockKey {
    lastBlockKey = blockKey
    speakContext(context)
}
```

becomes (conceptual — not production code):

```swift
if blockKey != lastBlockKey {
    lastBlockKey = blockKey
    if !isCruiseMode || CruiseVoicePolicy.shouldAnnounce(context: context) {
        speakContext(context, text: isCruiseMode
            ? CruiseVoicePolicy.utteranceText(for: context)
            : buildUtteranceText(context))
    }
}
```

Where `isCruiseMode: Bool` is the property set by `setCruiseMode(_:)`. `speakContext` receives an explicit text parameter rather than computing it internally, so the policy can inject Cruise Mode phrasing. The `voiceMinGapSeconds` guard in `speakContext` continues to apply regardless of mode.

---

## §5 — Entry and Exit

### 5.1 Entry: "Find Parking" button

**Placement:** Add a second Drive Mode entry path to the existing toolbar. The existing Drive button (arrow icon) opens `DriveModeDestinationView` (destination mode). The new "Find Parking" button enters Cruise Mode directly — no full-screen cover, no search UI.

**Visual treatment:** Two options:
- (a) A second button in the `recenterButtonStack` toolbar cluster. Label: "Find Parking" text pill or a dedicated SF Symbol (`location.magnifyingglass` or `car.front.waves.right.fill`).
- (b) Modify the existing Drive button to offer a choice: tap once → goes to `DriveModeDestinationView` as today; long-press (or a "skip" button inside `DriveModeDestinationView`) → enters Cruise Mode.

**Recommendation: option (a), standalone "Find Parking" button.** Long-press on the Drive button is not discoverable. A dedicated button is clear, mirrors the product logic (two distinct modes), and is the pattern patrol mode will reuse. `@designer` to review SF Symbol choice and button placement before the PR opens.

**Entry behavior:**
1. `driveModeStyle = .cruise`
2. `activeRoute = nil` (stays nil — no route fetch)
3. `driveDestinationCoordinate = nil` (stays nil)
4. `driveModeActive = true` → triggers existing `handleDriveModeChange(true)` → `locationService.startDriveMode()` → heading-up, auto-zoom, `.mutedStandard`, directional puck, wake lock, background note (all existing W8.5c–d paths fire unchanged)
5. `drivingContextService.setCruiseMode(true)` → voice policy switches to `CruiseVoicePolicy`

**Guard:** Same as destination mode — `guard activeSheet == nil else { return }` before activating (prevents opening Drive Mode when a sheet is already open).

### 5.2 Exit: "End Cruise"

The existing "End Drive" pill exits Cruise Mode identically to how it exits Destination Mode:
1. `driveModeActive = false` → triggers `handleDriveModeChange(false)` → `locationService.endDriveMode()`, camera restore, wake lock off
2. `driveModeStyle = .inactive`
3. `drivingContextService.setCruiseMode(false)` (reset for next session)
4. No `activeRoute` or `driveDestinationCoordinate` to nil out (already nil)
5. No arrival-prompt reset needed (`arrivalPromptFired` was never set)
6. `finalApproachState` reset to `.outside` (same as destination-mode exit — belt-and-suspenders)

**No Park-Until auto-fire.** OQ-3 resolved: "End Cruise" is ambiguous intent. User long-presses to drop a pin manually via W5 flow if they found a spot.

### 5.3 Considered: re-using existing entry point

The existing destination-mode spec (AC-DM.5) already contemplates no-destination operation: "User can skip destination input. Drive Mode functions (parking commentary, GPS follow, voice) without a destination." This was spec'd as a fallback, not a first-class entry. Cruise Mode promotes it to a first-class button. The distinction matters because AC-DM.5's no-destination path still goes through `DriveModeDestinationView`'s "Start without a destination" affordance (if it exists) or the implicit "just tap Start with nothing typed" behavior. Cruise Mode does not open `DriveModeDestinationView` at all — it is a direct entry. This is a UX improvement, not a spec contradiction.

---

## §6 — Architecture and Files

### 6.1 Codebases touched

**iOS only.** PWA is in maintenance mode. Backend is not touched — Cruise Mode is a client-side-only state machine. No new tables, RPCs, or tile changes.

### 6.2 New files

| File | Owner | Description |
|---|---|---|
| `ios/WePark/WePark/Services/CruiseVoicePolicy.swift` | @ios-engineer | Pure-function policy: `shouldAnnounce(context:) -> Bool`, `utteranceText(for:) -> String`, `minimumGapSeconds` constant. No framework imports. All-static enum, mirrors `FinalApproachService.swift` pattern. |
| `ios/WePark/WePark/WeParkTests/CruiseVoicePolicyTests.swift` | @ios-engineer | Unit tests for `CruiseVoicePolicy`. See §7. |

### 6.3 Modified files

| File | Change | Risk |
|---|---|---|
| `ios/WePark/WePark/ContentView.swift` | (1) Add `@State private var driveModeStyle: DriveModeStyle = .inactive`. (2) Add `enum DriveModeStyle { case destination; case cruise; case inactive }` (or nested type). (3) Add "Find Parking" button to toolbar. (4) Guard `handleFinalApproachUpdate` on `driveModeStyle == .destination`. (5) Set `driveModeStyle` at each Drive Mode entry/exit point. (6) Call `drivingContextService.setCruiseMode(true/false)` on entry/exit. | Medium — touches ContentView which is the #31 regression site. Live-UI smoke MANDATORY. |
| `ios/WePark/WePark/Services/DrivingContextService.swift` | (1) Add `private var isCruiseMode: Bool = false`. (2) Add `func setCruiseMode(_ isCruise: Bool)`. (3) Modify the `update(...)` block-change path to gate `speakContext` through `CruiseVoicePolicy.shouldAnnounce` when `isCruiseMode`. (4) Inject cruise-mode phrasing via `CruiseVoicePolicy.utteranceText` when active. | Low — surgical change to one branch of `update()`. Existing destination-mode path is unchanged. |
| `ios/WePark/WePark/Views/DriveModeBottomCard.swift` | No behavior change expected. The card already conditionally hides the distance indicator when `destinationDistance == nil`. The "Looking for street…" placeholder, left/right chips, and mute toggle are all unaffected by Cruise Mode. A doc-comment update noting Cruise Mode compatibility is optional but helpful. | Very low. |

**Do NOT touch:** `MapViewRepresentable.swift` (the camera/puck/heading stack is unchanged), `FinalApproachService.swift` (not called in Cruise Mode), `ArrivalPromptSheet.swift` (not called in Cruise Mode), `RouteService.swift` (no route fetch in Cruise Mode), `DriveModeDestinationView.swift` (not opened in Cruise Mode), `project.pbxproj`, `Info.plist`, `Config.xcconfig*`.

### 6.4 Mandatory live-UI smoke gate

`ContentView.swift` is modified. Per the hard gate established after the W8.5c-polish #31 revert (recorded in `ios-engineer.md` spec-fidelity norm and `HANDOFF.md` changelog 2026-05-26): before the PR is merged, the engineer AND QA agent must each take a simulator screenshot confirming the full overlay chain is intact:
- Gear button, find-me, find-my-car, clock, Drive button, NEW "Find Parking" button — all visible
- ASP banner rendered if applicable
- Park Until pill rendered if filter is active
- Drive Mode bottom card visible when Cruise Mode is entered

Kevin's manual smoke must confirm Cruise Mode entry, voice annotation, and exit on a real device or simulator before merge.

---

## §7 — Tests

**Baseline:** 300/0 (post-tier1-pin-display, PR #37 as noted in `tier3-patrol-mode-buildplan.md`).
**Target:** ~315/0 (+15 new tests, all passing without a real device).

### `CruiseVoicePolicyTests.swift` — target: 10 new tests

```
// shouldAnnounce decision table:
testShouldAnnounce_freeBothSides_returnsTrue
testShouldAnnounce_freeLeft_restrictedRight_returnsTrue
testShouldAnnounce_freeRight_unknownLeft_returnsTrue
testShouldAnnounce_meteredLeft_restrictedRight_returnsTrue
testShouldAnnounce_restrictedBothSides_returnsFalse
testShouldAnnounce_unknownBothSides_returnsFalse
testShouldAnnounce_restrictedLeft_unknownRight_returnsFalse

// utteranceText phrasing:
testUtteranceText_freeOnLeft_saysFreeParkingOnLeft
testUtteranceText_freeBothSides_saysFreeParkingBothSides
testUtteranceText_meteredOnlyNeitherFree_saysMeered
```

### `DrivingContextServiceCruiseModeTests.swift` (or additions to `W85cTests.swift`) — target: 5 new tests

```
testCruiseMode_restrictedBlock_doesNotSpeak
testCruiseMode_freeBlock_speaks
testCruiseMode_freeBlock_usescraisePhrasing   // verify utterance contains "Free parking" not "Left side, free until"
testDestinationMode_restrictedBlock_stillSpeaks // regression: destination mode is unchanged
testCruiseMode_blockChange_respectsMinGap       // voiceMinGapSeconds still applies
```

**Note on architecture invariants:** All new tests must pass without a real device. No `Calendar.current`. No `import SwiftUI` in service files. `DrivingContextService` tests inject `MockDrivingVoice` (already exists from W8.5c).

---

## §8 — Convergence with Patrol Mode

**This section is mandatory reading before patrol mode sub-PR #2 (`tier3-patrol-mode-buildplan.md`) starts.**

Patrol mode (`tier3-patrol-mode-buildplan.md` sub-PR #2) is described as "Patrol mode UI surface: mode entry, long-press report flow, report sheet." At its core, patrol mode needs:
1. The camera to follow the driver heading-up (same as Drive Mode)
2. Map overlays showing parking status (same as Drive Mode)
3. Voice to announce parking opportunities as the driver circles (same as Cruise Mode)

**Patrol mode REUSES Cruise Mode's camera/mode-state layer.** It does NOT independently re-implement the Drive Mode active session. The call chain for patrol mode is:

1. User enters patrol mode → `driveModeStyle = .cruise` (or a new `.patrol` variant — see below)
2. `driveModeActive = true` → existing `handleDriveModeChange(true)` fires, same as Cruise Mode
3. `drivingContextService.setCruiseMode(true)` → `CruiseVoicePolicy` governs voice, same as Cruise Mode
4. Patrol mode UI surface (the `PatrolView.swift` from sub-PR #2) overlays on top of the existing Drive Mode active layer — it does NOT replace it

**`DriveModeStyle` extension for patrol:** The `driveModeStyle` enum introduced by this spec should be designed with a `.patrol` case in mind. Recommend defining it as:

```swift
// Not production code — sketch for the engineer:
enum DriveModeStyle {
    case inactive
    case destination
    case cruise
    case patrol  // reserved for tier3 sub-PR #2; behavior = cruise + community reporting layer
}
```

Patrol mode's voice behavior is a superset of Cruise Mode's `CruiseVoicePolicy` (it adds community pin callouts — "Enforcement ahead" — in `tier3-patrol-mode-buildplan.md` sub-PR #6). By reserving the `.patrol` case now, patrol mode can extend the voice behavior via a `patrolVoiceGate` check in `DrivingContextService` without re-architecting the mode system.

**Explicit hand-off contract:** When patrol mode sub-PR #2 is built, the engineer must:
1. Read `driveModeStyle` as `@State` in `ContentView` — do not duplicate this state
2. Set `driveModeStyle = .patrol` at patrol mode entry (not `.cruise`)
3. Keep `driveModeActive = true` as the shared activation signal
4. Reuse `handleDriveModeChange` unchanged — do not fork it for patrol
5. `PatrolView.swift` is an overlay on the existing active-layer stack, not a replacement bottom card

**What this spec prevents:** Without this explicit convergence section, a patrol-mode engineer might see "the camera and overlays run in Drive Mode" and decide to implement a separate `patrolModeActive: Bool` that duplicates `driveModeActive`, creating two parallel paths to maintain. This spec forecloses that.

---

## §9 — Acceptance Criteria

QA verifies all of the following against the merged code. These are the delta ACs on top of the existing destination-mode ACs (AC-DM.* from `drive-mode-scope-spec.md` §10 and AC-W85c.* from `w8.5c-drive-mode-active-spec.md` §5).

**Entry — "Find Parking" button**
- [ ] **AC-CM.1** A "Find Parking" button is visible on the main map screen alongside (or near) the existing Drive Mode button. It is not inside `DriveModeDestinationView` — tapping it enters Cruise Mode directly without presenting the full-screen destination search cover.
- [ ] **AC-CM.2** Tapping "Find Parking" sets `driveModeActive = true`, `activeRoute = nil`, `driveDestinationCoordinate = nil`, and `driveModeStyle = .cruise`.
- [ ] **AC-CM.3** The existing Drive button (destination mode entry) continues to work correctly after this PR. Entering destination mode, completing a route, and ending Drive Mode all pass the W8.5d acceptance criteria.

**Camera and overlays (reuse verification)**
- [ ] **AC-CM.4** On Cruise Mode entry, the map applies the same camera transitions as Destination Mode: auto-zoom to `~0.005°` span, 45° pitch, `.mutedStandard` map style, heading-up rotation, directional puck. All camera transitions fire via the existing `handleDriveCameraChange(_:)` path — no second `.onChange(of: driveModeActive)` block is introduced.
- [ ] **AC-CM.5** The `DriveModeBottomCard` is visible with street name and Left/Right chips. The distance indicator is absent (correct — `destinationDistance == nil`). The approaching strip is absent (correct — Cruise Mode never enters `.approaching`).
- [ ] **AC-CM.6** Parking overlay polylines (red/green/yellow) are visible in Cruise Mode at the auto-zoomed span.

**Voice policy**
- [ ] **AC-CM.7** When the driver enters a block where BOTH sides are restricted (severity `.restricted`) or have no data (severity `.unknown`), `DrivingVoice` does NOT speak. The bottom card chips update silently.
- [ ] **AC-CM.8** When the driver enters a block where at least one side is free (severity `.free`), `DrivingVoice` speaks within 12 seconds. The announcement uses Cruise Mode phrasing: it contains "Free parking" as the lead, not "Left side, free until...".
- [ ] **AC-CM.9** When the driver enters a block where at least one side is metered (severity `.metered`) and neither side is free, `DrivingVoice` speaks with metered phrasing.
- [ ] **AC-CM.10** The voice minimum gap (12s baseline) applies in Cruise Mode. Two block changes within 5 seconds of each other do not produce two voice cues within 12 seconds.
- [ ] **AC-CM.11** Mute toggle works in Cruise Mode. Tapping mute stops in-flight speech and suppresses subsequent announcements. The mute state persists across Cruise Mode and Destination Mode sessions (same `UserDefaults` key).

**Route-dependent behavior is absent**
- [ ] **AC-CM.12** `handleFinalApproachUpdate` is NOT called during Cruise Mode. `finalApproachState` remains `.outside` for the duration of the session.
- [ ] **AC-CM.13** The arrival prompt (`ActiveSheet.arrivalPrompt`) is NEVER presented during a Cruise Mode session, regardless of how close the driver gets to any coordinate.
- [ ] **AC-CM.14** `driveModeDistanceMeters` is nil throughout a Cruise Mode session (or is never updated from a non-nil base — confirm by code inspection).

**Destination Mode regression**
- [ ] **AC-CM.15** All existing destination-mode ACs (AC-DM.1–28 from master spec §10, all AC-W85c.*, all W8.5d ACs) still pass after this PR is merged. Specifically: the full destination-mode flow (enter destination → route fetch → drive → final approach → arrival prompt) works unchanged. `CruiseVoicePolicy.shouldAnnounce` is not called in destination mode (unit test: AC-W85c.20 and `testDestinationMode_restrictedBlock_stillSpeaks` both pass).
- [ ] **AC-CM.16** `xcodebuild test` exits 0 with at least 315 tests passing (300 baseline + 15 new). No new `Calendar.current` use. No `import SwiftUI` in service files.

**Live-UI smoke (mandatory pre-merge gate)**
- [ ] **AC-CM.17** Simulator screenshot before Drive Mode entry shows full toolbar layer intact: gear, find-me, find-my-car, clock, Drive (destination), Find Parking (cruise) — all visible. ASP banner present if applicable. No regression of the #31 overlay chain.
- [ ] **AC-CM.18** Simulator screenshot after Cruise Mode entry shows: `DriveModeBottomCard` visible, "End Drive" pill visible and clearing the ASP banner, toolbar buttons hidden or replaced per Drive Mode UX conventions. Parking polylines visible.
- [ ] **AC-CM.19** Kevin's manual smoke confirms: (a) Cruise Mode entry activates from one tap; (b) map tilts and zooms to ~1-2 blocks; (c) voice announces "Free parking on [side]" when circling a free block; (d) voice is silent on restricted-only blocks; (e) "End Cruise" / "End Drive" exits cleanly and restores the pre-drive camera.

---

## §10 — Open Decisions (punted)

**"Find Parking near me" suggestion list.** When the user taps "Find Parking," the map is already centered on their GPS position and the overlay is live. A brief "nearby free blocks" summary before they start driving — e.g., a sheet showing the top 3 free blocks within 500m — was considered and deferred. It requires a spatial query on loaded segments, a mini-list UI, and design work. Not the right scope for Cruise Mode's launch slice, which is deliberately minimal. Defer to a TF2 enhancement.

**Voice escalation near a free block.** If the driver is within 100m of a free block on an adjacent block, should Cruise Mode proactively announce it ("Free parking 1 block to your right")? This is lookahead geometry — requires heading vector + projected path, not just the current block. Deferred: adds significant complexity to the voice policy and would be the first spec to require predictive positioning. Worth speccing if drive-test feedback says users miss free blocks because they passed them without warning.

**Haptic pulse on free-block detection.** `tier3-patrol-mode-buildplan.md` has `UIImpactFeedbackGenerator.medium` on free-block entry (from `drive-mode-scope-spec.md` NQ-2). Cruise Mode is the natural place to land this too. Deferred to patrol-mode sub-PR #2 (which already contemplates haptic) rather than adding it in this PR — patrol mode will set the haptic precedent and Cruise Mode can inherit it in a TF2 polish pass.

---

## §11 — Work Stream Decomposition

Cruise Mode is a single-PR spec per OQ-5. No parallel streams within this feature — all files are owned by `@ios-engineer`.

| Stream | Owner | Serializes after | Estimate |
|---|---|---|---|
| **CM-1** — `CruiseVoicePolicy.swift` + `CruiseVoicePolicyTests.swift` | @ios-engineer | Nothing (pure new files, no existing code dependency) | 0.5 sessions |
| **CM-2** — `DrivingContextService` cruise-mode extension + tests | @ios-engineer | CM-1 (uses `CruiseVoicePolicy`) | 0.5 sessions |
| **CM-3** — `ContentView` entry button + mode-state + guards | @ios-engineer | CM-2 (must test `setCruiseMode` path) | 0.5 sessions |
| **CM-4** — Live-UI smoke + QA pass | @qa-verifier | CM-3 merged | 0.5 sessions |

**Total: ~1.5 engineer sessions + 0.5 QA sessions = 2 sessions.** This is the correct order of magnitude for a subtractive spec.

**`@designer` review:** The "Find Parking" button placement should be reviewed by `@designer` before CM-3 starts. A design note at `docs/design/cruise-mode-button.md` (or a sketch in the PR description) showing the button in the toolbar cluster is sufficient for this scale of change.

---

*Spec written by @tech-lead 2026-06-04. Engineer: read §3 before writing any code — the routing-guard section is the load-bearing part. QA: AC-CM.17 and AC-CM.18 (live-UI smoke) are merge-blocking; AC-CM.19 requires Kevin's manual smoke before the PR is closed. Do not self-sign-off.*
