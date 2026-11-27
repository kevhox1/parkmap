# DT35: park flow and drive-mode fixes (from Kevin's build 35 drive test)

Source: `docs/field-testing-log.md`, section "2026-11-27, Drive test, build 35", items DT35-1 to DT35-6. DT35-7 (Houston) is owned elsewhere and not covered here.
Owner of the build: `@ios-engineer`. Backend / PWA: no work. `@designer` is optional (see PR3).
All new UI is Stoop-only: gated on `StoopFlag.designSystemV2Enabled` (`ios/WePark/Shared/Stoop/StoopFlag.swift:19`, reached in app code as `AppConstants.designSystemV2Enabled`). With the flag off, every legacy screen and code path stays byte-identical. Every new pure helper is `nonisolated` (the project defaults to MainActor isolation).

## Read first (decisions, all adopted unless Kevin vetoes)

1. **One-way streets are the main case, not the edge case.** In the bundled tiles 80% of segments are `oneway: true` (38,217 of 47,696; `tiles/tile_*.json`), and **both Stanton St sides are one-way**. "You pull over to the right" only holds on two-way streets (20% of segments). On a one-way street heading says nothing about the side. So the side fix leans on GPS geometry plus an honest **ask**. Expect the app to ask "Which side?" fairly often on one-way streets. That is intended: Kevin's rule is "if unsure, ask, don't guess".
2. **GPS alone cannot separate the curbs on most streets.** Median distance between the two curb lines of a block in the tiles is 13.8 m (Stanton 12 to 15 m; p10 12 m, p90 22 m). Real city-canyon GPS is 8 to 20 m. So the nearest-line pick that shipped is close to a coin flip.
3. **Root cause of DT35-2 (two bugs, not one).** (a) The drive "Park here" picks `candidates.first`, the nearest line by raw GPS, with no side logic (`ContentView.swift:5277-5296`). (b) The "Wrong street?" list can never offer the other curb: `CandidateSegmentSearch.findCandidateSegments` dedupes by `street|from|to` with no side in the key (`Services/CandidateSegmentSearch.swift:52-61`), so both sides of a block collapse into one candidate. Kevin had no way out.
4. DT35-1 is a **"Free until" picker** (weekday chips + a 30 min time stepper), not a day count. Range: Overnight end to midnight after day 8. Default = today's auto ladder end. Earlier than Overnight clamps up, so green nests in Overnight and A few hours. See PR4.
5. In Stoop, long-press "Park here" and the arrival prompt move onto the same new park card (PR3). The needle-pin curb placement mode (`curbPinPlacementEnabled`) stays for **Report** only.
6. No new flags, no `Constants.swift` edits. New tunables live in their own `nonisolated enum` next to each helper (house style: `DriveSideConstants`).

## Build recipe notes

- Stoop-on build (same as build 35): `StoopFlag.designSystemV2Enabled = true`; in `Constants.swift`: `driveModeDefaultEnabled`, `onboardingStoryEnabled`, plus the tester flags build 35 used (`curbPinPlacementEnabled`, `addressAnchoredParkingEnabled`, `myCarSheetV2Enabled`).
- `addressAnchoredParkingEnabled = true` is needed for the "In front of 15 Stanton St" line and for the address under each side in the "Which side?" chooser. The park flow must still work (no address line) with it false.
- The repo defaults stay `false`. Guard tests (`DesignSystemV01Tests.testFlag_defaultsFalse`, `CurbPlacementSessionPolicyTests`) must keep passing. Flip flags only in the archive recipe.
- Xcode 27.2 license is not accepted yet, so nothing here can be built until that clears. Whoever dispatches `@ios-engineer` must paste in the "Swift compile-failure classes (6)" list, including: bare `Category` is ambiguous in test targets, so write `WePark.Category`.
- New test files go in `ios/WePark/WeParkTests/` and must be members of the `WeParkTests` target.

## PR order and parallel lanes

| PR | Item | Depends on | Lane |
|----|------|-----------|------|
| PR1 | DT35-2 wrong side | none | A (park chain) |
| PR2 | DT35-3 free drag, pending vs saved | PR1 | A |
| PR3 | DT35-4 Stoop park flow + checklist | PR2 | A |
| PR4 | DT35-1 For-days Free-until picker | none | B |
| PR5 | DT35-5 direction of travel | none | C |
| PR6 | DT35-6 legal label | none | D |

Lane A serializes (PR1 to PR3 all edit `WPParkFlowV2.swift` and the park functions in `ContentView.swift`). Lanes B, C, D touch different files and can run in parallel with lane A and each other. Only `ContentView.swift` is shared: keep edits there to small, separated hunks, and rebase, never reformat.

---

## PR1: DT35-2 wrong side at Park here (highest priority)

### Current behaviour and why
- Drive "Park here" (`WPDriveBottomV2.onPark`, `ContentView.swift:4542`) runs `driveParkHereTapped` (`ContentView.swift:5277`). It calls `findCandidateSegments(lat,lng,radius: pinDropRadiusMeters = 35, max: 4)` (`ContentView.swift:1219`, `:8376`). Winner = `candidates.first`, the segment whose polyline is nearest the GPS point. Pin = raw GPS. No heading, no accuracy check, no opposite-side check.
- Then `.signCheckConfirm` (checklist, `ContentView.swift:1935`) then `.parkConfirm` (`ParkConfirmView`, `ContentView.swift:1711`), whose "Wrong street?" rows are `candidates.dropFirst()`. Per cause (b) above these never include the other curb of the same block.
- `confirmPinDrop` (`ContentView.swift:8218`) saves `detectedSegmentID`/`detectedSide` from that segment. `ensureParkedCarAddress` (`:8250`) then resolves the address. `ParkingAddressGeometry.probePoint` (`Services/ParkingAddressResolver.swift:73`) probes 8 m toward the segment's compass side, so a wrong side gives the wrong building ("11" for "15").
- Token drag path: `WPParkFlowController.update` (`Views/WPParkFlowV2.swift:78`) snaps to the nearest curb within 40 m (`snapMeters`, `:50`). That is deliberate user input, but there is no way to flip to the other curb either.
- Curb-sheet "Park here" (`v2ParkOnCurb`, `ContentView.swift:4652`): the user tapped a specific curb line, so the side is known. Not a side bug (position bug, see PR2).
- Arrival prompt "Park here" (`ContentView.swift:~1981-2014`) saves with `detectedSegmentID: nil, detectedSide: nil`. No side, no verdict on My Car. Same bug class.
- Location data available: `LocationService` keeps only the latest fix. The drive branch of `didUpdateLocations` (`Services/LocationService.swift:498-515`) does NOT record `horizontalAccuracy` (only the non-drive branch does, `userHorizontalAccuracy`). Course, speed and course accuracy are available per fix.

### The change

**1A. Track buffer (`LocationService`).** Add a small ring buffer of `ParkTrackFix { coordinate, course?, courseAccuracy?, speed, horizontalAccuracy?, timestamp }` appended on every fix in both branches (drive and single-shot). Keep at most 40 fixes, at least 1 s apart, drop anything older than 120 s. Also set `driveHorizontalAccuracy` in the drive branch. Expose a read-only `recentTrack`. Cleared on `endDriveMode`. Never persisted, never logged (privacy rule in the address spec).

**1B. Pure `ParkSideResolver` (new `Services/ParkSideResolver.swift`, all `nonisolated`).**

```swift
enum ParkSideDecision: Equatable {
  case confident(ParkSidePick)            // segment, foot-point coordinate, fraction, basis
  case ask(ParkSideChoice)                // exactly two candidates, no verdict allowed
  case onlyCurb(ParkSidePick)             // no opposite curb in the data
  case weakFix                            // accuracy unusable: do not pick anything
  case noCurb                             // nothing within 35 m
}
enum ParkSideBasis { case geometry, pulledRight, geometryAndHeading, onlyCurb, userChose }
static func decide(fix: ParkTrackFix, track: [ParkTrackFix], segments: [Segment]) -> ParkSideDecision
```

Steps (thresholds in `ParkSideConstants`):
1. **Fix quality.** Fix older than 10 s, accuracy nil, or accuracy > 65 m (same bar as `AmbientDrivingLook.maxTightHorizontalAccuracyMeters`, `Services/AmbientDrivingLook.swift:60`) gives `.weakFix`.
2. **Candidate pair.** A = nearest segment within 35 m. B = `CandidateSegmentSearch.oppositeSideCandidate(of: A, in: segments)` (`Services/CandidateSegmentSearch.swift:119`, exact cross-street match first, geometric fallback). No B: `.onlyCurb`. Nothing in range: `.noCurb`.
3. **Position.** Use the mean of the fixes in the last 10 s with speed < 1 m/s (stopped), else the latest fix. Uncertainty `sigma = max(bestReportedAccuracy, 5 m)`. Do NOT divide by sqrt(n): GPS error is correlated.
4. **Geometry vote.** `dA`, `dB` = distance to each polyline. `z = (dB - dA) / sigma` (positive favours A). Decisive if `|z| >= 2`. With a 12 to 14 m curb gap that needs sigma of about 6 m or better.
5. **Heading vote, two-way streets only (`A.oneway == false`).**
   - Approach bearing: fixes in the last 120 s with speed >= 2.0 m/s and `courseAccuracy` nil or <= 30 deg; need >= 2; circular mean; circular spread <= 25 deg; the final moving fix must be within 60 m of the stop. This works even if Kevin took 30 s to tap Park here.
   - Must be within 30 deg of the street axis at the foot point (else he was turning: no vote).
   - Vote = the curb on the **right-hand side** of the travel bearing. Compute with a cross product of travel vector and (street midline to curb foot point), in east/north metres. Never use the N/S/E/W side letters for this, so it survives Manhattan's angled grid.
   - One-way streets and `oneway == nil`: **no heading vote**.
6. **Decide.**
   - `|z| >= 2`: take the geometry side. If a two-way heading vote disagrees, `.ask` (reason: signals disagree). Else `.confident`.
   - `|z| < 2` with a two-way heading vote and `z` not leaning against it (`z * vote > -1`): `.confident(.pulledRight)`.
   - Anything else: `.ask`.
   - **Never break a tie by nearest-GPS.** That is the bug.
7. Foot point: project the (averaged) position onto the chosen polyline (`nearestPointOnPolyline`). The saved coordinate is that foot point.

**1C. Stoop side-aware card replaces `ParkConfirmView` in Stoop** (new `WPParkSideCardV2` in `Views/WPParkFlowV2.swift` or a new `Views/WPParkSideCardV2.swift`). Same checklist step in front for now (the checklist is reskinned in PR3). Entry points wired to `ParkSideResolver`: drive Park here (`driveParkHereTapped`), arrival-prompt Park here. States:
- **confident**: shows address line ("In front of 15 Stanton St" when available), the verdict (existing `WPVerdictBlock` via `WPNeighborVerdict.resolve`), the primary "Park here" (`RaisedButtonStyle(.commitment)`), and a large secondary **"Other side of the street"** button (full width, min height `WP.Target.minimum` 48 at default, 64+ in drive).
- **ask**: title "Which side of Stanton St?". Two large side-by-side buttons (stack at AX sizes), **"Left side" / "Right side"** as the main label, with the compass side as a smaller secondary line ("North side" via `WPCurbCopy.sideLabel`, `DesignSystem/WPCurbSheetLogic.swift:330`, in the Stoop caption/secondary style). **Kevin 2026-11-27: people often don't know which way is north; left/right is what they see.**
  - **Left/right reference:** the direction the car was travelling when it stopped (the retained approach course). NYC requires parking with the flow of traffic, so on a **one-way** street that's the street's direction and left/right is unambiguous. On a **two-way** street, label them "Right side" (the side you were driving on) and "Left side" (across the street).
  - **No usable course** (e.g. long-press park, walked back to the car, GPS course invalid): the reference is the direction the **phone is facing** (compass heading), and the title says "Facing the street from your car, which side?". If there's no heading either, fall back to compass labels as the main text ("North side" / "South side"). Never show a left/right label we can't anchor.
  - The same left/right main label plus small compass text is used everywhere a side is shown in Stoop: the "Other side of the street" result, the My Car "Wrong side? Switch" row, and the address sub-line. Don't use "North/South" alone as the primary label in Stoop.
  - Tests: one-way eastbound street, car travelled east, north curb → "Left side (North)". Two-way street approach heading → right = travel side. No course plus heading → phone-relative. Neither → compass fallback. The map highlights both curbs and the car dot stays visible. **No verdict, no "free until", no green/red on the buttons.** If `addressAnchoredParkingEnabled` and the resolver returns a `.verified` address for a side, show it as the sub-label ("Near 15 Stanton St"); otherwise omit (resolver is rate limited to 6/min, two probes fit). Tapping one gives `.confident(basis: .userChose)` and the verdict appears.
- **weakFix**: "Waiting for a better GPS signal" plus a "Place it on the map" button (opens the PR2 drag flow). No guess.
- **noCurb / onlyCurb**: `noCurb` falls to today's no-data copy (`CurbPlacementCardCopy` wording); `onlyCurb` has no switch button (hidden, not disabled).
- "Other side of the street" swaps to the opposite segment at the same position along the street (project the current foot point onto B), re-runs the verdict and address (`addressCoordinator.placementSnapChanged`), and toggles back on a second tap. Basis becomes `.userChose`.

**1D. Same switch on the token path.** `WPParkConfirmCard` (`Views/WPParkFlowV2.swift:390`) gets the "Other side of the street" button (new `onSwitchSide` closure; `WPParkFlowController` gets `switchSide(...)`). The token's side stays "what the finger dropped on"; no ask state there, because the user pointed at a curb.

**1E. Fix it after saving.** My Car (`Views/WPMyCarV2View.swift`) gets a "Wrong side? Switch" row (Stoop only). It needs `ParkPinService.replaceSide(carID:, with segment:, coordinate:)` (pattern: `updateAddress`, `Services/ParkPinService.swift:270`): saves a new `ParkedCar` with the same id, recomputes address, cancels and reschedules reminders (`NotificationScheduler.cancelAllThenSchedule`), bumps the iCloud envelope. If this slips, ship PR1 without 1E and land it as PR1b.

### Edge cases
- Divided / wide streets and avenues: `oppositeSideCandidate` allows up to 60 m lateral. Dedicated-carriageway pairs (see `docs/ft21-carriageway-investigation.md`) may pair the wrong carriageway; the ask still works (user picks), the verdict is only shown after.
- A one-sided block (park on one side only, or B missing from the tile): `.onlyCurb`, no switch.
- Cross streets / intersections: nearest A might belong to the cross street; the 30 deg axis check drops the heading vote and the 2-way ask handles it.
- User stopped for minutes before tapping: stationary averaging covers position; heading comes from the retained approach.
- Pulled into a space after a U-turn: the approach bearing is the post-turn one; fine.
- Both sides give identical verdicts: still ask (address and reminders depend on the side). Not optimised.
- Never log coordinates or addresses.

### Acceptance criteria
- [ ] Stanton St replay fixture (two parallel E-W curb lines 12 m apart, both `oneway: true`, car on the south curb, fix 12 m accurate and biased 5 m north so nearest-GPS would pick north): decision is `.ask`, **never** `.confident(north)`.
- [ ] Same fixture with a 4 m accurate fix on the south curb: `.confident(.geometry)` south.
- [ ] Two-way street, eastbound approach of 25 m at 6 m/s, stop mid-gap (z ~ 0): picks the south (right) curb, basis `.pulledRight`. Westbound: north. Works on a street rotated 29 deg (Manhattan avenue) with identical results.
- [ ] Two-way, geometry decisive for the left curb but heading says right: `.ask`.
- [ ] Turning approach (spread > 25 deg) or approach not aligned within 30 deg: no heading vote.
- [ ] Accuracy 80 m or fix 15 s old: `.weakFix`, nothing saved without user action.
- [ ] In the ask state no verdict text, no green/red tint and no "free until" is on screen (UI test on the model, plus VoiceOver label check).
- [ ] "Other side of the street" flips segment, verdict and address line in one tap; second tap returns. The saved `ParkedCar.detectedSide`, `detectedSegmentID` and coordinate match what was last shown.
- [ ] After saving on the wrong side, My Car "Wrong side? Switch" updates side, address, verdict and reminders (old notification ids cancelled).
- [ ] Arrival-prompt Park here now saves a `detectedSegmentID`/side (or asks).
- [ ] Flag off: `ParkConfirmView` and `signCheckConfirm` flow unchanged; legacy tests unchanged.
- [ ] Buttons >= 64 pt in drive, text scales to AX5 without clipping the primary button.

### Tests to add
- `ParkSideResolverTests`: fixtures from `CurbSnapTestFixtures.swift`; the six geometry/heading cases above, rotation invariance (0 and 29 deg), `oneway` true/false/nil, tie never resolved by distance, stationary averaging, stale approach rejected (> 60 m away or > 120 s).
- `ParkTrackBufferTests`: cap 40, 1 s spacing, 120 s expiry, cleared on `endDriveMode`, drive branch records accuracy.
- `CandidateSegmentSearchTests`: add a regression that documents the dedupe (opposite side is NOT in `findCandidateSegments` output), so nobody "fixes" the Wrong-street list by accident.
- `StoopParkSideCardTests`: model state to copy (ask has no verdict string), switch toggles, no-opposite hides switch.
- `ParkPinServiceSyncTests`: `replaceSide` keeps id, bumps envelope, reschedules.

---

## PR2: DT35-3 free drag along the block, pending vs saved

### Current behaviour and why
- Curb sheet "Park here" saves instantly at `segment.midpoint ?? coordinates.first` (`v2ParkOnCurb`, `ContentView.swift:4652`; `Segment.midpoint` is `coords[count/2]`, `Models/Segment.swift:88`). One tap, no preview, no drag: this is the "locks to a sign or snap point" Kevin felt (segments can be sub-block pieces cut at sign zones).
- The draggable car token only exists at rest: `v2ShowsRestingToken` requires `activeSheet == nil` and no parked car (`ContentView.swift:~4630`). Tapping a curb opens the sheet, which hides the token.
- Token flow: `WPParkFlowController` (`Views/WPParkFlowV2.swift:29`) stores `tokenPoint` in **window coordinates**, and while `.placed` a full-screen `Color.clear` catcher (`:204`) blocks map pan and pinch. So you cannot zoom to place precisely on a 12 m wide street, and a drag only works from the token.
- `endDrag` with no curb in range calls `reset()` (token flies home, `:140-150`). Drag hysteresis (`CurbSnapConfig.hysteresisMeters`) is capped at about 4 m, so crossing to the other curb works but feels sticky.
- "Saved" today = `confirmPinDrop` (`ContentView.swift:8218`) via `ParkPinService.save`, which also schedules reminders and syncs. Nothing marks "not saved yet".

### The change (Stoop only)
1. **Placement draft** (new `WPParkDraft`, value type in `WPParkFlowV2.swift`): `groundCoordinate` (the raw finger point on the ground), `snap: CurbSnapResult?`, `basis`, `model: WPCurbSheetModel?`. The token is positioned by projecting `groundCoordinate` (`pointForCoordinate`) and re-projected whenever the map region changes (`ContentView.region` onChange). This replaces window-point storage and removes the need for the pan-blocking catcher in `.placed`: **map pan and pinch stay live while pending**.
2. **Free drag.** While dragging, the car icon follows the finger exactly (keep the existing lift offset so the finger does not hide it). The snapped landing is shown as a small dot on the curb under it, and the verdict bubble updates live. On release the car glides to the foot point. Position along the block is continuous (no snapping to vertices, signs or the midpoint). The side flips as soon as the other curb is nearer (use `CurbSnapConfig` with a smaller hysteresis than the placement mode, about 1.5 m, for the token).
3. **Verdict stays live.** Re-evaluate whenever the `segment.id` changes (already the case, `:92-107`), including mid-block changes between sub-segments and across to the other side.
4. **Off-curb release.** In `.placed` / pending, releasing beyond 40 m returns the car to its last valid curb (not home), with the bubble "Drop the car on a curb". Only an unplaced first drag goes home.
5. **Curb-sheet "Park here" no longer saves.** It closes the sheet and enters pending: car on the curb at the foot point of the user's GPS fix if within 40 m of that blockface, else at `midpoint`. Side is the tapped curb (certain). User can drag, flip with "Other side of the street", then confirm.
6. **Pending vs saved** (the only two states, shown to the user):
   - **Pending** = `WPParkDraft` exists. Nothing is written: no `ParkedCar`, no iCloud, no reminders, no Live Activity, no My Car. The card shows a chip **"Not saved yet"** and the car token is drawn with a dashed outline.
   - **Saved** = the user tapped "Park here" / "Park here anyway" and `confirmPinDrop` ran. Token turns solid, success haptic, card is replaced by the My Car / reminder flow (PR3).
   - Cancel, tapping elsewhere that closes the card, entering Drive Mode, or app termination discards the draft. A draft is never persisted.
7. The map selection highlight follows the draft's segment (`selectedSegmentID`, as `v2ParkLayer` does at `ContentView.swift:~4690`).

### Edge cases
- Dragging while the snap index is not ready (`indexReady == false`): show "Getting the map ready" and queue the first resolve (existing `prepareIndex`).
- Accessibility sizes hide the resting token today; the "Park my car" row (`v2PlaceCarAtUser`, `ContentView.swift:~4640`) must create a pending draft too, and the pending token must be movable with VoiceOver actions: "Move forward along the block", "Move back", "Switch side" (nudge 5 m along the polyline).
- Trip plan active: unchanged (`guard tripPlan == nil`).
- Outside coverage: unchanged (`v2OutsideCoverage`).

### Acceptance criteria
- [ ] Drag the car along one block: the snap dot and token move continuously; the saved coordinate equals the foot point at release (test to 1 m), not a vertex, sign point or the midpoint.
- [ ] Drag across the street: side and verdict flip within one frame after crossing the centre line (+/- 2 m).
- [ ] While the card is up, pinch-zoom and pan work; the token stays glued to its ground point.
- [ ] Curb sheet "Park here" never writes a `ParkedCar`; only the confirm button does.
- [ ] "Not saved yet" is visible (and spoken) in pending, gone after save.
- [ ] Backgrounding or cancelling leaves no `ParkedCar`, no pending notification requests, no iCloud write.
- [ ] Release off-curb in pending returns to the last valid curb.
- [ ] Flag off: no change.

### Tests
- `WPParkDraftTests`: pending writes nothing (fake `ParkPinService` records zero saves), saved writes once; discard paths; draft never encoded.
- `WPParkFlowControllerTests`: continuous fraction (no snap to vertices), side flip at the centre line with the token hysteresis, off-curb release returns to last curb, region change re-projects the token.
- `Phase2bCurbSearchParkTests` (existing): update the curb-sheet Park here expectation from "saves at midpoint" to "enters pending at foot point".

---

## PR3: DT35-4 Stoop park flow (checklist kept)

### Inventory of the legacy flow and what replaces each screen

| Today (file:line) | Used by | In Stoop becomes |
|---|---|---|
| `SignCheckConfirmView` (`Views/SignCheckConfirmView.swift`, sheet `ContentView.swift:1935`). 5 optional checkboxes, system fonts, 44 pt checkboxes. | drive Park here only | The checklist **section** of the new park card (`WPParkChecklist`). Same five items, same optional (never gates the button), same wording intent, in Stoop type and 64 pt rows. |
| `ParkConfirmView` (`Views/ParkConfirmView.swift`, `ContentView.swift:1711`): "Park my car", Wrong-street list, "Remind me" toggle, Cancel / Park here. | drive Park here, legacy long-press, Path B | Replaced by `WPParkSideCardV2` (PR1) plus a Stoop reminder toggle row. "Wrong street?" list is dropped in Stoop (replaced by "Other side of the street"). |
| `WPParkConfirmCard` (`WPParkFlowV2.swift:390`): Stoop, no checklist, no reminder choice. | token drag | Same new card, so every entry point behaves alike. |
| `v2ParkOnCurb` instant save (`ContentView.swift:4652`) | curb sheet | Pending card (PR2). |
| `CurbPlacementCard` (`Views/CurbPlacementCard.swift`) + `CurbPlacementController` needle pin | long-press, Path B, Report pill when `curbPinPlacementEnabled` | Park: long-press drops the pending car token at that point (PR2 draft). Report keeps the needle pin. Legacy card untouched when flag off. |
| Arrival prompt Park here (`ContentView.swift:~1981`, direct save, no segment) | drive arrival | Same new card, prefilled from the fix. Skips the legacy `ParkUntilSheet` (`ContentView.swift:2014`); that sheet is a goal filter, not part of parking. |
| `NotificationRationaleView` | first park | Already Stoop (`WPReminderPrimingSheet`, `WPParkFlowV2.swift:495`). Keep. |
| My Car after save | all | Already Stoop-capable (`WPMyCarV2View`, `myCarSheetV2Enabled`). Keep. |

### The new flow (one card, three parts)
1. **Where**: address / street + side, "Other side of the street", "Not saved yet" chip (PR1/PR2 pieces).
2. **Is it OK**: the verdict block (`WPVerdictBlock`), plus the existing warning copy for non-clear curbs (`WPParkCopy.warning`, `WPParkFlowV2.swift:462`).
3. **Check the curb** (new `WPParkChecklist`): heading "Take 10 seconds. The signs are the final word." and the same five rows (read all signs; 15 ft from a hydrant; not blocking a driveway or curb cut; not in a bus stop or no-standing zone; check today's street-cleaning status). Rows are 64 pt tall toggle buttons with a Stoop check mark, never required. At AX sizes the checklist scrolls, with the Park here button pinned below it (reuse the `WPFitScroll` pattern from `WPDriveV2.swift:325`).
4. **Remind me** row (default on, same default as `ParkConfirmView`), one line using `WPParkCopy.reminderLead`.
5. Pinned primary "Park here" / "Park here anyway".

In the drive flow the checklist is open by default (Kevin loves it for new users). On the token and curb-sheet paths it starts collapsed behind a "Check the curb" row, and **auto-opens until the user has saved a car once** (reuse `hasEverParkedKey`), so new users still see it. `@designer` review is optional (the pieces are existing Stoop components); if used, the deliverable is a review of the card at default and AX5 sizes, landed by the orchestrator (the designer agent has no Bash).

### Acceptance criteria
- [ ] Every Stoop entry point (drive Park here, token, curb sheet, long-press, arrival, "Park my car" row) ends on the same card; no legacy sheet (`SignCheckConfirmView`, `ParkConfirmView`, `CurbPlacementCard`) appears with the flag on. A test enumerates `ActiveSheet` cases presented by the park paths with the flag on.
- [ ] Checklist: five items, toggling does not change the enabled state of Park here, state resets for each new card, VoiceOver reads "Checked / Unchecked" per row.
- [ ] First-ever park shows the checklist open on every path; afterwards drive keeps it open, others collapse.
- [ ] Targets >= 64 pt; Dynamic Type to AX5: primary button always on screen, checklist scrolls, nothing truncates (render tests as in `DriveAXLayoutTests`).
- [ ] Plain-language copy only; no "ASP", no "intent", no "blockface".
- [ ] Flag off: legacy flow byte-identical.

### Tests
- `StoopParkChecklistTests`: five rows, non-gating, reset per card, AX layout render at default and AX5 (iPhone SE-height budget).
- `StoopParkFlowRoutingTests`: flag on routes each entry to the new card, flag off to the legacy sheet.
- Update `Phase2bCurbSearchParkTests`, `W7Tests` expectations that referenced `ParkConfirmView` for flag-on only.

---

## PR4: DT35-1 For-days "Free until" picker (weekday + time)

Kevin's update: he wants to pick an exact end, for example "Tuesday at 9 AM" or "Monday at 5 PM", not a day count. This replaces the earlier -/+ days idea.

### Current behaviour and why
- "For days" = `.parkAndForget`. Every `rebuildOverlays` runs `resolveParkAndForgetViewport` (`ContentView.swift:2982-2994`, function at `:8948`), which walks `ParkingGoals.parkAndForgetLadderOffsetDays = [8, 4, 2]` (`Services/ParkingGoals.swift:123`) and picks the first rung where **any** loaded segment is clear. Ends are always local midnights (`now.startOfDayET(offsetDays:)`). Result lives in `forDaysResolution` (`ContentView.swift:649`) and feeds `WPGoalSheetInput.forDaysEnd` (`Views/WPMapScreenV2.swift:25`).
- The map's green bucket is one single end applied to every segment through `engine.isFree(segment:from:until:)` (`Services/ParkingRulesEngine.swift:719`). So an arbitrary end time needs **no engine change**: just set `parkUntilTarget` to the picked `Date`.
- Copy assumes a midnight end: `WPGoalCopy.headlineEnd/tileUntil` use `lastClearDay(end - 1s)`, `countdown` uses `spanDays` (`DesignSystem/WPMapLogic.swift:~114-175`).
- The goal sheet (`WPGoalSheetV2`, `Views/WPMapScreenV2.swift:96`) has no control for this. The Overnight "lever" (`leverOpen`, chips) is the nearest precedent.
- **Plan a Trip picker (checked):** `WPTripPlannerV2` (`Views/WPTripPlannerV2.swift:178-200`) uses a SwiftUI `DatePicker(.date, .hourAndMinute)` in `.wheel` style, opened from a 64 pt row (`dateRow`), plus `WPChoiceChipStyle` chips. Reusable: the row-opens-wheel pattern, `WPChoiceChipStyle`, `WPTripCopy.rowStamp`, and `.environment(\.timeZone, .easternTime)`. Not reusable as is: SwiftUI's wheel has no 15/30 min interval (only UIKit's does), the wheel is small at AX5, and Trip allows past/any dates. So Free until reuses the pattern and styles but uses big chips and a +/- time stepper, not the system wheel, as the primary control.

### The change (Stoop only)
**Decisions (adopted):**
- **Range:** from the Overnight end (see nesting) to the end of the 8th day (`startOfDayET(offsetDays: 8)`, shown as "midnight"), which is the same top as today's ladder. 8 weekday chips: Today, Tomorrow, then weekday names.
- **Time step:** 30 minutes (matches "9 AM / 5 PM" talk and keeps the stepper to 48 taps per day; 15 min doubles that for no real benefit).
- **Default:** Auto = today's ladder best end, exactly as build 35 (so nothing changes until he touches it). The picker opens showing that end pre-selected.
- **Relation to the other goals:** the invariant is green(A few hours) is a superset of green(Overnight), which is a superset of green(For days) (`docs/specs/goals-rework.md` section 1, `ParkingGoals.target` comment `:157`). So the earliest selectable end is the **Overnight end** (`ParkingGoals.overnightEnd`, which honours the user's morning-hour lever). Anything earlier is clamped up with a plain note: "Overnight already covers this. Use Overnight for earlier." Free until never shows more green than Overnight. For-days with the earliest end equals Overnight's green.

**Control** (inside the goal sheet when For days is selected; `forDaysUntil: Date?`, nil = Auto):
1. Headline row (64 pt, tappable, same pattern as `dateRow`): "Free until  Tue 9:00 AM" + "Change". Tapping opens the picker inline (one open at a time, as `editing` in the trip planner).
2. **Day**: single-select chips (`WPChoiceChipStyle`, min height 64 pt, 8 chips; they wrap via `WPChipFlowLayout`, `Views/WPSettingsV2.swift:100`, at AX sizes one per row).
3. **Time**: large [ - ] 9:00 AM [ + ] stepper in 30 min steps (72 pt circle buttons, `WP.Target.driveMin`), VoiceOver `adjustable` (increment/decrement by 30 min, value read as "Tuesday 9:00 AM"), selection haptic, optional press-and-hold repeat (0.25 s). Under it four quick time chips: 7 AM, 9 AM, 12 PM, 5 PM (and "Midnight"). Stepping past the day's ends rolls into the neighbouring day only inside the allowed range; at the range ends the button disables (and is announced as unavailable).
4. "Auto" chip while manual: resets to the ladder. Done button closes the picker.
5. Persist `forDaysUntil` (`@AppStorage` next to the overnight hour, `ContentView.swift:626`, stored as an ET timestamp). On launch or foreground, if it is at or before the current minimum (now / Overnight end) reset to Auto, so a stale "Monday 5 PM" never lingers.

**Window and map.** The map's green end is always the **effective end** `T*` (equal to the picked end when something nearby is clear, else the best-available fallback below). `parkUntilTarget = T*` (on the 30 min grid), `strictGreen: true`, the unchanged single-target loop (`ContentView.swift:~3040-3070`). Green = curbs that stay legal **from now through `T*`**, and `T*` is the time shown in the headline, tile and banner. Green never reflects the requested time when that differs from what is shown. `forDaysResolution` is bypassed in manual mode (replaced by `WPForDaysState` below); the legacy `EmptyMapGuardKind` enum is reused as is (cases `.steppedDown`, `.empty`), no new case, so the `GoalSelectorView` switches are untouched.

**Copy** (new Stoop-only helpers; keep the midnight paths for Auto):
- Headline: `ParkingGoals.weekdayDateLabel` + `WPGoalCopy.clock`, for example "Tue 12/1, 9 AM". Tile sub-line: "until Tue 9 AM". Countdown: "1 day 4 h from now" (days and hours, never "1 days"). Never use `lastClearDay` for a non-midnight end.
- Lead line stays "Green curbs are free from now until".

**Nothing free until the picked time: fall back to the best available, loudly (Kevin's decision).** Never silent, never green for the requested time.

*How `T*` is computed.* `WPForDaysState { requested, effective (T*), isFallback, greenCount, kind }`, computed in `rebuildOverlays` over `tileLoader.segments` (the loaded tiles, exactly the set the ladder uses for "nearby") with the strict predicate (`WPCurbVerdict.isParkable(segment:engine:from:until:)`):
1. `n(T)` = number of loaded segments clear from now until `T`. Clear-until is monotonic: clear until T implies clear until any earlier time, so `n` is non-increasing in `T`.
2. If `n(requested) > 0`: `T* = requested`, no fallback.
3. Else `T*` = the **latest grid step in `[minEnd, requested)` with `n > 0`**, found by binary search over the 30 min grid (about 9 evaluations, each one pass over the loaded segments; only runs in the fallback case). `minEnd` is the Overnight end (nesting rule above).
4. If `n(minEnd) == 0`: `.empty`, no green anywhere, `T* = minEnd` for display only. Never stretch below Overnight and never colour a curb that is not clear.
5. Nesting holds by construction: `minEnd <= T* <= requested`, and monotonicity gives green(requested) subset of green(T*) subset of green(Overnight). Add a property test. This is the manual-mode analogue of the Auto ladder's step-down (`resolveParkAndForgetViewport`, `ContentView.swift:8948`, which stays in charge when the picker is on Auto and keeps its `.steppedDown` / `.sparse` banners).
6. Thin fallback: if `n(T*)` is below `defaultBannerDensityThreshold` (0.25) of `n(minEnd)`, append "Only a few curbs." to the detail line.

*What happens when the user pans.* The state is recomputed on the same triggers as the ladder (`rebuildOverlays` on tile load and on region settle, never during a gesture), so a pan can change `T*`, or clear the fallback entirely if the new area has a curb clear until the requested time (it then snaps back to `requested` with no banner). It is always recomputed from what is loaded; a stale fallback is never kept. When `T*` changes while the user is looking, post a VoiceOver announcement ("Best nearby is now free until Mon 5 PM") and animate the headline cross-fade only (no layout jump). The user's pick (`forDaysUntil`) is never overwritten by the fallback.

*Copy (Stoop style, plain words, `WPGoalCopy` additions).*
- Banner box above the headline, dashed `WP.noParkLine` outline like `WPTripPlannerV2.problemBox`, bold line then regular line:
  - Fallback: **"Nothing nearby is free until Tue 9 AM."** / "Best nearby: free until Sun 8 PM."
  - Empty: **"Nothing nearby is free until Tue 9 AM."** / "No clear curbs found very nearby. Try Overnight, or pan the map."
- Headline slot shows `T*`: "Free until Sun 8 PM" (not the requested time). Lead line "Green curbs are free from now until" stays true because it names `T*`. Goal tile sub-line: "until Sun 8 PM". Countdown from `T*`.
- The picker row keeps showing the request ("You asked for: Tue 9 AM") so the user can see the gap and change it.
- `kind` maps to the existing `EmptyMapGuardKind.steppedDown` / `.empty` so shared chip/icon styling is reused; the sentences are the new Stoop strings above (not `bannerCopy`, which says "full week").

*AX5 layout.* Follows the existing AX dock rule (`EmptyMapGuardKind.chipCopy` as the dock chip, full sentence as the first row of the goal sheet; dock budget 40%, 45% with a banner, `ambientOverlayBottomPadding`, `ContentView.swift:~9020`):
- Dock (resting): one chip with a complete phrase that includes the time: **"Best nearby: until Sun 8 PM"** (empty: "No clear curbs nearby"), min 64 pt, wraps, never truncates. Tapping it opens the full goal sheet.
- Goal sheet at AX sizes (full height, scrolls): order is banner box (both lines, wrapping, no line limit), headline "Free until Sun 8 PM" (two lines allowed), "You asked for: Tue 9 AM" row (64 pt, opens the picker), then the tile rows. Done / Park buttons stay pinned; the banner is never collapsed away.
- VoiceOver reads the banner as one element: "Nothing nearby is free until Tuesday 9 AM. Best nearby: free until Sunday 8 PM."

### Edge cases
- DST: build the end with `Calendar.easternTime` (`bySettingHour:minute:` on the chosen ET day); the 30 min grid is wall-clock. Spring-forward 2:00 to 3:00 AM does not exist: the stepper skips it. Fall-back 1:00 to 2:00 AM repeats: pick the first occurrence, the grid still has one 1:30 AM entry.
- The minimum (Overnight end) moves as time passes and with the morning lever (`setOvernightMorningHour`): re-clamp on every rebuild; if the current pick falls under it, bump it up and show the clamp note once.
- The 8th day's latest time is "midnight" (start of day 8), shown as "midnight Tuesday night", not "12 AM Wed".
- Rapid taps: 150 ms debounce on `rebuildOverlays`; the count pass is one extra loop (plus the binary search only when zero). Measure on device; auto mode already does 3 passes.
- Trip plan and `fullPaletteMode` skip this block as today (`ContentView.swift:2972`).
- AX5: the picker is a scrolling sheet section; Done pinned; dock height must stay within the AX dock budget (`AXGoalDockTests`, `ambientOverlayBottomPadding`, `ContentView.swift:~9020`): when open at AX sizes, the picker takes the full-height detent rather than growing the dock.

### Acceptance criteria
- [ ] Default launch: identical to build 35 (auto ladder, same tile and headline text).
- [ ] Picking "Tuesday 9:00 AM": headline "Tue 12/1, 9 AM", tile "until Tue 9 AM", countdown correct, green = exactly the segments for which `isFree(from: now, until: thatDate)` is true (test against the engine).
- [ ] Green(end T2) is a subset of green(end T1) for T1 < T2, and green(For days) is a subset of green(Overnight) at the minimum end, on a multi-day fixture.
- [ ] Picking earlier than the Overnight end clamps up and says why; it never shows more green than Overnight.
- [ ] Range: first selectable = Overnight end, last = midnight after day 8; stepper buttons disable at both ends; 30 min grid.
- [ ] Nothing free until the picked end: banner says "Nothing nearby is free until <requested>. Best nearby: free until <T*>.", headline/tile/countdown show `T*`, and the green set equals exactly the segments clear from now until `T*` (test against `isFree`/`isParkable`), never the requested end.
- [ ] `T*` equals a brute-force scan of the 30 min grid for the latest end with at least one clear curb (binary search correct), and is never below the Overnight end.
- [ ] Green(requested) is a subset of green(`T*`), which is a subset of green(Overnight); holds on a multi-day fixture.
- [ ] Panning to an area where the requested end has green removes the banner and uses the requested end; panning back recomputes the fallback. No stale fallback; no recompute mid-gesture.
- [ ] Even the Overnight end has no clear curb: "No clear curbs found very nearby. Try Overnight, or pan the map.", no green.
- [ ] AX5: dock chip shows "Best nearby: until <time>" untruncated; the goal sheet shows both banner lines in full; VoiceOver reads one combined sentence.
- [ ] "Auto" restores the ladder result; a stale stored pick resets to Auto.
- [ ] Day chips, stepper and quick chips are at least 64 pt (stepper 72 pt) and work at AX5; VoiceOver can set day and time with adjustable actions only.
- [ ] Flag off: `GoalSelectorView` and Park Until behave as before.

### Tests
- `ForDaysUntilTests`: step grid (30 min), clamp to Overnight end including the morning-hour lever, range end at day 8, DST spring-forward and fall-back days in ET, stale-pick reset, midnight display.
- `ForDaysNestingTests`: subset properties above using `ParkingGoalsTests` fixtures.
- `ForDaysFallbackTests`: `T*` binary search equals brute force; monotonic nesting property; `.empty` at the minimum; thin-fallback threshold; recompute on tile-set change (pan) switches between fallback and requested; green set built from `T*` not `requested`; copy strings for both kinds.
- `WPGoalCopyTests` additions: headline, tile and countdown for non-midnight ends; midnight ends unchanged.
- Render tests for the picker and the fallback banner at default and AX5 (pattern: `DriveAXLayoutTests`).

---

## PR5: DT35-5 direction of travel in drive mode

### Current behaviour
The Stoop drive street pill shows only `WPDriveVerdict.streetTitle(context.street)` (`ContentView.swift:4520`, `DesignSystem/WPDriveLogic.swift:221`, `WPDriveTopChromeV2` in `Views/WPDriveV2.swift:371`). `DrivingContext` has no heading or segment (`Services/DrivingContextService.swift:52`). Heading data exists: `LocationService.driveHeading` (EMA of GPS course, frozen when idle), `driveSpeed`, `driveCourseAccuracy`, `driveHeadingHeld` (`Services/LocationService.swift:179-214`); the matched segment is `DrivingContextService.matchedSegment` (read at `ContentView.swift:~6490`).

### The change (Stoop only)
New pure `WPDriveDirection` in `DesignSystem/WPDriveLogic.swift`:

```swift
static func label(segment: Segment?, heading: Double?, speed: Double?, headingHeld: Bool, courseAccuracy: Double?) -> String?
// "Eastbound" | "Westbound" | "Northbound" | "Southbound" | nil
```

- **Street axis from the tile's own convention, not from true north.** Tiles name curb sides N/S for streets that run crosstown and E/W for avenues. So `segment.side` in `{N,S}` means label axis E/W; `{E,W}` means label axis N/S. This is what makes Manhattan's grid (avenues about 29 deg off true north, streets about 119 deg) read the way New Yorkers say it.
- **Which way.** Take the travel bearing `t` = the street's local bearing at the car's position, or that +180, whichever is within 60 deg of `heading` (same tolerance as `DriveSideConstants.alongStreetToleranceDeg`). For an E/W axis: Eastbound if `sin(t) > 0` else Westbound. For an N/S axis: Northbound if `cos(t) > 0` else Southbound. These signs are stable for any street within +/- 45 deg of its axis, so the 29 deg tilt cannot flip a label.
- **Diagonals** (Broadway, Bowery): the same rule on the side-letter axis; if the street's geometric bearing is within 20 deg of 45 deg off both axes, or the side-letter axis disagrees with the geometry by more than 60 deg, return nil rather than guess.
- **Not moving, no claim.** Use the **raw GPS course** (`driveHeading`; never the street-snapped heading from `DriveHeadingSnap`, which would be circular). Show only when `speed >= 2.0 m/s`, `!headingHeld`, and `courseAccuracy` nil or <= 30 deg. Hide after 3 s below 1.0 m/s (hysteresis, so a short slow-down at a light does not flicker). The 3 s state lives in a tiny value type `WPDriveDirectionGate` (testable, no timers in the view).
- **Turns.** A heading more than 60 deg from the street axis (mid-turn) returns nil.
- **Wrong way on a one-way street:** the label reports actual movement (truthful). The existing wrong-way logic owns warnings; do not duplicate.
- UI: `WPDriveTopChromeV2` gets `direction: String?` (default nil). Pill text "Stanton St" + " \u{00B7} Eastbound" as one wrapping `Text` (wraps by words at AX sizes; no extra row). VoiceOver: "Street: Stanton St, eastbound". Short forms (E/W/N/S) only if the pill would overflow at the largest drive type size, via `ViewThatFits`.
- No spoken direction in `DrivingVoice` (out of scope).

### Acceptance criteria
- [ ] Stanton St (sides N/S), moving at 6 m/s on bearing 100 deg: "Eastbound"; on 280 deg: "Westbound".
- [ ] 2nd Ave (sides E/W, axis about 29 deg), bearing 25 deg: "Northbound"; 205 deg: "Southbound". Same result for 5 deg and 55 deg headings within tolerance.
- [ ] Speed 0.5 m/s: no suffix after the 3 s grace; 1.5 m/s: unchanged state (hysteresis); heading held: no suffix.
- [ ] Mid-turn (heading 80 deg off axis): no suffix.
- [ ] Snapped-heading source never feeds the label (test passes a heading equal to the street bearing with `headingHeld == true`: nil).
- [ ] AX5: pill wraps, no clipping, End button still reachable.
- [ ] Flag off: legacy `DriveModeBottomCard` unchanged.

### Tests
`WPDriveDirectionTests`: the table above; rotation sweep 0 to 359 deg on both axes asserting no label contradicts the side-letter axis; gate hysteresis; diagonals return nil. Reuse `DriveSidesAndIdleHeadingTests` helpers.

---

## PR6: DT35-6 Apple Maps legal label under the drive buttons

### Current behaviour and why
`mapRepresentable` is `.ignoresSafeArea()` and the drive card is a **later** `.safeAreaInset(edge: .bottom) { bottomSafeAreaContent }` (`ContentView.swift:3256-3279`). The inner `ignoresSafeArea` lets the map extend under the card, so MapKit pins its Apple logo / Legal link to the screen bottom, directly under the Report / Park here / Voice row (`WPDriveBottomV2`, `ContentView.swift:4370`). The repo already has the right mechanism, but only for curb-pin placement: `CurbPlacementController.setBottomInset` (`Views/CurbPlacementController.swift:707`) sets `mapView.layoutMargins.bottom` (with the `insetsLayoutMarginsFromSafeArea` snapshot/restore dance), wired through `CoordinatorActions.setPlacementBottomInset` (`Views/MapViewRepresentable.swift:1049`, `:1682`) and `applyCurbPlacementBottomInset` (`ContentView.swift:~7430`). That code is commented **UNVERIFIED on device**.

### The change (Stoop only)
1. Add a general `CoordinatorActions.setBottomChromeInset(_ height: CGFloat)` in `MapViewRepresentable`, independent of placement (new small `MapMarginController` or a method on the Coordinator, same snapshot/restore logic as `setBottomInset`; placement and drive are mutually exclusive, but keep the snapshots separate so neither restores the other's).
2. In `ContentView`, while `v2DriveActive && driveModeActive`, measure the drive card's height (`.onGeometryChange(for: CGFloat.self, ...)`, already used in this file) and call `setBottomChromeInset(height + 8)`; clear (0) on drive exit, on sheet presentation that covers it, and on `endDriveMode`. Hop one run-loop turn, never from `updateUIView` (rule from #31, as in `applyCurbPlacementBottomInset`). Measure the stack, not a constant, so AX sizes (card up to 55% of the screen) and the final-approach strip are handled.
3. The attribution stays visible and unmodified. Do not hide it, restyle it or cover it with a custom view (Apple requires it). If it ends up above a tall card at AX5, that is acceptable.
4. Same fix for the browse goal sheet and the park card is **recommended** (the same overlap exists there), but only the drive card is required for this PR; wire the goal sheet if the measured-height seam makes it a one-line change.

### Risks to verify on device first (cheap spike before writing the rest)
- Does changing `layoutMargins` re-centre the map? In drive mode the follow camera re-applies every fix, so a one-time shift is harmless; confirm there is no visible jump at drive entry.
- Does iOS honour `layoutMargins` for the Legal link when `insetsLayoutMarginsFromSafeArea` is false on this OS (Xcode 27.2 toolchain)? If not, fallback: in drive mode only, reorder to `.safeAreaInset` first and `.ignoresSafeArea(.container, edges: [.top, .horizontal])` second, so the map frame ends above the card. This changes the follow-camera centre; re-tune `driveModeCameraSpan` / pitch offsets if used.

### Acceptance criteria
- [ ] Drive mode on an iPhone with a home indicator and on one without: the Apple logo and Legal link are fully visible and do not touch any of Report / Park here / Voice off (min 8 pt gap).
- [ ] Holds at default size, AX3 and AX5, with and without the final-approach strip, and when the card height changes.
- [ ] Attribution is unmodified (assert `mapView` attribution views are not hidden; manual screenshot in QA notes).
- [ ] Leaving drive mode restores the original margins exactly (`layoutMargins` and `insetsLayoutMarginsFromSafeArea` equal pre-drive values).
- [ ] No camera jump on entering/leaving drive mode; no margin write inside `updateUIView`.
- [ ] Legacy drive card and placement mode unchanged with the flag off.

### Tests
`MapBottomInsetTests`: pure policy for "inset = measured + 8, clamp to 60% of height, 0 when not driving" (mirror `CurbPlacementMapPolicy.bottomMargin`, `Services/CurbPlacementMapPolicy.swift`), snapshot/restore round trip on a plain `MKMapView`, no-write-in-update guard (same pattern as existing #31 tests). Manual QA on device for the visual criteria.

---

## Out of scope follow-ups (noticed, punted)

- Both curbs showing the same verdict still ask for the side. Could skip the question when the answer cannot matter, but the saved address and reminders depend on the side, so deliberately not done.
- Learning from corrections (if the user often taps "Other side", tune `sigma`): needs analytics we do not have. Add local-only counters later.
- Voice callout of direction ("Eastbound on Stanton"): separate decision, affects `CruiseVoicePolicy`.
- Dedupe in `findCandidateSegments` hides the opposite curb for every legacy caller (Report sheet's confirm-the-street list already uses `confirmStreetCandidates`, which is fine). Left as is to keep legacy byte-identical.
- Browse goal sheet and Stoop park card also sit over the Legal link; fixed only if PR6's seam makes it trivial.
- DT35-7 (Houston curb offsets) is owned by another agent; PR1's opposite-curb pairing on divided streets (see edge cases) depends on its geometry fix.

## Summary and PR order

Kevin's wrong-side park is two bugs: the drive Park here takes the GPS-nearest curb with no side logic, and the "Wrong street?" list cannot offer the other curb because candidates dedupe both sides of a block into one. 80% of tile segments (including all of Stanton St) are one-way, so "pull over to the right" helps on only 20% of streets, and 12 to 14 m curb gaps are inside normal GPS error. The spec therefore adds a pure `ParkSideResolver` (stationary-averaged geometry plus a retained approach-heading vote on two-way streets only) that returns confident, ask or weak-fix, never a guess, plus a one-tap "Other side of the street" switch and a post-save "Wrong side? Switch". It then makes placement a draft ("Not saved yet") that can be dragged continuously and across the street with pan and zoom live, folds the checklist into one Stoop park card used by every entry point, and ships the For-days "Free until" picker (weekday chips plus a 30 min time stepper, default the auto ladder end, clamped so green nests inside Overnight, a loud fallback when nothing nearby is free that colours green only to the best-available end it names, found by binary search), a cardinal direction label derived from the tiles' own side convention with a not-moving gate, and a measured bottom map inset that lifts the Apple Maps legal link above the drive buttons.

PR order: PR1 DT35-2 side fix, PR2 DT35-3 free drag and pending/saved, PR3 DT35-4 Stoop park flow with checklist (serial lane A); PR4 DT35-1 For-days Free-until picker, PR5 DT35-5 direction of travel, PR6 DT35-6 legal label (independent lanes, run in parallel with lane A).
