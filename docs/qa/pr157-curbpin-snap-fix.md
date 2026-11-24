# PR #157 curb-pin snap fix: live QA (2026-11-23)

**Reviewed:** branch `fix/curbpin-snap-2026-11-23` (CI green), live on iPhone 17 sim (iOS 26.5), local flag-on build (`driveModeDefaultEnabled` + `curbPinPlacementEnabled` = true, not committed), location 40.7236,-73.9877 (E 1st / E Houston, East Village).
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
The headline complaint is fixed live. After a drag release the camera stays put; the ghost and tether stay on the snapped curb, and there was no settle nudge in any release I measured. Acquire at 15 m, the no-curb state, the chip landing, the YOUR SQUARE hide/restore, the new ground mark, Park here and Cancel all behave. Nothing blocks. One finding is that ruling 3 (geometric opposite side) has no user-visible effect, because the only UI it feeds can no longer appear. One method gap is that I could not set up a clean "E Houston north side, then is the south side found" case. Everything pinch, rotate and on-device remains device-only.

## Per-check results

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | No camera move after user-drag release; ghost/tether stay | PASS | Burst screenshots at ~1/2.2/3.4/4.6 s after release, byte-compared (`cmp`). Slow and medium drags (3-5 s swipes, 40-120 pt) were identical across all four frames, with the card unchanged. Four releases, including s4/t1/r2/r3 with the tip ~25-30 pt from the curb (ghost visibly offset from the tip, tether drawn): no movement. A fast 0.5 s flick (r1) differed between frames 1 and 2, then was identical 2/3/4. Frame 1 shows the lifted pin and the map still decelerating. This is MapKit inertia in the swipe direction. A nudge would pull the curb toward the tip, and here the curb ended farther from the tip. Images `snapSettled.png`, `dragMark.png`. |
| 2 | Tip mid-lot / >15 m from curb gives no-curb state | PASS | Mid-block lot at start: "No curb here", chip "Nearest curb 110 ft", "Save car here (no parking info)". Second lot: "Nearest curb 70 ft". Neither snapped to a far curb (the old 24 m acquire would have). `noCurb.png`, `zoneHiddenPlacement.png`. |
| 3 | Tip within ~10-15 m snaps, card correct | PASS | E 1 St North side ("between E HOUSTON ST & 1 AVE"), E 1 St South side, E Houston North side ("between E 1 ST & 1 AVE"). Highlight, ghost and card agreed each time. |
| 4 | E Houston 1-2 Ave: opposite side found / south side snappable | PARTIAL | North side snapped. South side snapped directly: card "E Houston St · South side, between ORCHARD ST & LUDLOW ST" (the cross-street names differ from the north side, which is the ruling-3 case). No "Nearest curb with data" footnote appeared in any snapped state. See finding 1: that footnote can no longer fire, so the geometric opposite match is not observable in the UI. Ruling 3 itself verified only by the new unit tests (CI green), not live. |
| 5 | Chip tap still nudges; landing offset | PASS, offset ~7-12 pt | Chip tapped twice from no-curb. Run 1: crosshair tip (592,1030), highlight/ghost centre ~(600-612,1000-1010) in 1185-wide screenshot px, so ~20-35 px ≈ 7-12 pt. Run 2: ghost ~(612,1000), same result. The ghost lands ON the tip, not ~100+ pt off. The open layoutMargins/setCenter concern did not reproduce on iPhone 17 at the default Dynamic Type. `chipLanding.png`. |
| 6 | YOUR SQUARE polygon | PASS | The sim does show a home-zone dashed blue boundary (near the E 2nd St edge, top of the map). Ambient: visible (screenshot after Park here). Placement: long-pressed 38 pt below the line, so the line should sit ~38 pt above the tip; none drawn. Cancel: dashed line is back (`x1`). Back after Park here: also visible. `zoneHiddenPlacement.png` vs `zoneBackAfterCancel.png`. |
| 7 | Ground mark dot + crosshair | PASS | Black dot with crosshair at the tip, at rest (`noCurb.png`) and on a lifted pin mid-drag (`dragMark.png`, larger crosshair). Readable over dark basemap, lot and road. I could not hold a finger and screenshot at the same instant with AXe, so the true finger-down frame is not captured (see device-only). |
| 8 | Park here, Cancel, AX1 | PASS | Park here: placement exits, parked-car pin appears at the snapped E Houston curb (on the building-side curb line, not the roadway). Re-entering after that, the old car pin still shows. Cancel: clean exit, dock rows and zone line return. AX1 (`accessibility-medium`): card keeps legality ("Free until Monday 8:00 AM", wraps to 2 lines) and Park here; Report row falls below the fold, ASP banner hidden (pre-existing AX behaviour). `ax1card.png`. |

## Findings

### Blocking
None.

### Significant
None.

### Minor
- **#1 (`@ios-engineer`): ruling 3 is invisible and the far footnote is now dead code.**
  - Where: `CurbPlacementCard.swift:64,296` (`farCurbThresholdMeters = 15`, `isFar = snapped.distanceMeters > 15 && !oppositeSideLoaded`) with `CurbSnapConfig.defaultAcquireRadius = 15`.
  - What: A snap is only produced at <=15 m, so `isFar` can never be true. `oppositeSideLoaded` (the only consumer of the new geometric match in the placement flow) therefore never changes anything on screen. The Houston "Nearest curb with data" footnote is gone, but because of the radius change, not because of the geometric match.
  - Expected: either the threshold should be below the acquire radius if the footnote is still wanted, or the footnote and `oppositeSideLoaded` plumbing should be removed. Ruling 3 should also be confirmed to matter somewhere (the block-select "Both curbs" path, deliberately left out of scope in the PR, is where a user would see an opposite side).
  - Repro: any snapped state, read the code; no live state can show the footnote.
- **#2 (`@ios-engineer`): block-select "Both curbs" still uses name-only opposite side.** `ContentView.oppositeSideSegment`. PR flags it; the Houston case will still miss in block-select. Follow-up, as the PR says.
- **#3: pinch-out ceiling.** The PR loosened `testPinchOutCeiling_keepsTheAcquireRadiusAtLeast40pt` to 39 pt instead of lowering the ceiling (39.4 pt at 600 m). Orchestrator call; not a defect.

### Out of scope (logged)
- Two-tier snap choice: at one position the tip was equidistant between E 1 St South and E Houston South curbs and snapped E 1 St. Plausible (nearest in ground plane on a pitched map); not a bug, noted for device feel.

## Device-only / not verified
- Finger-down frame of the ground mark (AXe cannot hold a drag and screenshot).
- Pinch, rotate, pitched-map rotation behaviour, the 2 m side dead-band (flip-smoke M1/M4).
- Real fingertip occlusion of the 10 pt dot / 24 pt crosshair on a physical iPhone.
- Whether the user-drag inertia (frame 1 of the flick) feels like "auto locks back" to Kevin: the camera does not recenter on the curb, but a fast flick still glides then stops. Worth a sentence in the on-device retest.
- Chip landing offset at AX Dynamic Type sizes (checked only default Large; the AX1 pass was legality/primary only).
- ruling 3 live (see finding 1): unit-test-only.

## Smoke tests run
`xcodebuild build` (no tests) of the PR with the two flags on locally: succeeded. Installed, launched, location granted, onboarding skipped. Long-press entry to placement; drag swipes via AXe (slow, medium, fast); chip tap x2; Park here; Cancel; AX1 content size; `cmp` of screenshot bursts; screenshots read visually (assets under `docs/qa/assets/pr157/`). Tests were not run locally per instructions (CI green).

## What's working
- The snap-back is gone in every drag case I could produce.
- 15 m acquire gives a truthful no-curb state with a useful nearest-curb chip in lots and wide roads.
- Programmatic chip nudge lands on the tip.
- Zone polygon hide/restore and the new dot + crosshair mark are clearly visible and clean.
- Park here saves on the snapped curb; Cancel exits cleanly; the AX1 card keeps legality and the primary action.

## Cleanup
Constants.swift reverted, Config.xcconfig copy deleted, sim shut down, app uninstalled, derived data deleted.
