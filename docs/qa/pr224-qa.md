# PR #224 QA (DT35-3 drag the car, pending vs saved, F1, F2)

Reviewed: branch `ios/dt35-3-drag-car` at `a6247b1e`, against `docs/specs/dt35-park-flow-and-drive-fixes.md` (PR2), `docs/field-testing-log.md` DT35-3, `docs/qa/pr221-qa.md` (F1, F2).
QA agent did not build this. Sim `wepark-qa224-sim` (iOS 26.5), flags flipped locally and reverted, nothing pushed except this report.

**Verdict: PASS with follow-ups.** No blockers. The core rule holds: the verdict always belongs to the curb the dot or car is on, pending writes nothing, Park here saves the shown curb. One real defect in the VoiceOver nudge at block ends (S1), and a per-frame CPU cost while pending (S2).

## Results

| Area | Result |
|---|---|
| Full `WeParkTests`, shipped flags (all off), PR head, `-parallel-testing-enabled NO -jobs 4` | 3348 run, 1 skipped, 0 failures. No flakes hit. Flag-off unchanged. |
| Dry-run merge vs `origin/main` (`51cfe54d`) | Clean (`git merge-tree`, no conflicts). |
| Dry-run merge vs PR #223 (`ios/dt35-6-legal-label`) | Clean. |
| Own real-tile probe, `docs/qa/pr224-assets/QA224ProbeTests.swift.txt` | drag, flip, off-curb, F2 pass. Nudge and F1 findings below. |

## Real-tile probes (independent; ENU geometry plus brute-force nearest curb)

Blocks: Stanton Bowery-Chrystie (8 pieces), Lexington E105-106, Madison E74-75, Broadway W101-102, Broadway E10-12 (labels differ between sides). Not the builder's fixtures.

- **Drag along each piece, 2 m off the curb toward the street** (about 860 steps): 0 wrong snaps. The snapped point is the foot of the finger on the snapped piece (within 0.5 m), within 1.6 m of the true nearest curb. The verdict model equals a freshly built verdict for the snapped segment in all steps (no stale model). Largest jump between consecutive 1 m steps: 4 m (a piece boundary on Broadway). Crossing piece boundaries is clean.
- **Cross the street at fixed along-position** (117 crossings): flip happens when the new curb is closer by 0 to 1.9 m (dead-band 1.5 m plus 0.2 m step). Never early, never stuck.
- **Off-curb**: finger 900 m away gives snap nil and model nil (no stale verdict). Release restores the last curb. A second consecutive off-curb release also restores it. Restore sets the "Drop the car on a curb" notice.
- **F2 exact flip-back** (all pieces, 5 positions, 5 blocks, 191 flips): `WPSideFlipMemory` returns the original piece and coordinate exactly in every case, including Broadway where labels differ. The old re-projection would have drifted or hopped in 4 of those cases (Lexington, Broadway W101-102). Live: 221 to 237 to 221 Chrystie.
- **F1 mini-map**: on Stanton 39 of 40 sampled pairs have identical x extents (aligned). 1 of 40 does not. On Lexington 2 of 30, Madison 6 of 35, Broadway W101-102 10 of 30, Broadway E10-12 9 of 56 are NOT aligned. In every one the facing piece overlaps the car's piece by under 5 m (`minimumCommonSpanMeters`), so clipping is skipped and the trapezoid remains. Honest, but F1 is only partly closed on avenues and Broadway (see M1).
- **Nudge +/-5 m**: see S1.

## Rule: never show a verdict for a spot the car isn't on

- While dragging, the bubble is the model of the snapped curb, and the dot marks it (code plus probe). Not stale.
- Beyond the snap radius (40 m, nothing in range) the bubble says "Not on a curb" and clears model and snap. Verified in probe (model nil).
- **Caveat (S3): over a building or the centre line it does NOT say "Not on a curb".** The snap reach is 40 m, unchanged from before. In the probe a finger up to 24 m from the nearest curb (mid-lot between streets) still shows that curb's verdict. The dot marks the curb and release lands the car on it, so it is not a stale or wrong verdict, but it does not match "over a building it says Not on a curb". If Kevin wants that literally, the verdict reach needs shrinking (for example 12 to 15 m). Flagging as a product call rather than a bug; the spec kept 40 m.
- Release off-curb restores the last curb with the notice. First-ever drag goes home. OK.
- Pending writes nothing: `WPParkDraft` is not Codable and has no service dependency. Live: tapped Cancel and the map returned with no parked car. Park here ran `confirmPinDrop` and the car appeared solid on the shown curb. Saved and shown positions matched (West side, same spot).
- Not done: killing the app mid-pending on the sim. Covered by the draft being memory-only and by the builder's tests; recommend Kevin do it once.

## Deviation judgments

1. **Curb-sheet pending only when `driveModeDefaultEnabled` is on.** Acceptable. Note shipped repo defaults for these flags are all `false` (`Constants.swift:266`); Stoop builds must flip `driveModeDefaultEnabled` on, or Kevin gets the old one-tap save with no pending. Confirm the TestFlight flag script flips it.
2. **weakFix "Place it on the map" unchanged.** Acceptable (placing automatically would guess a side).
3. **True middle of curb, not `Segment.midpoint`.** Correct and better.
4. **Move became Cancel, no `basis`, `recenterMap` resets zoom.** Cancel is fine. The zoom reset is a concern (M2): `v2RevealPendingCar` calls `recenterMap`, which sets a street-level region. It only triggers when the car lands behind the card or near the top (`revealIfHidden`), so a user who zoomed in to place precisely and drops near the bottom loses their zoom. Not observed destroying a placement live, but worth a drive check.
5. **Per-frame `TimelineView`.** See S2.

## Findings

### Significant
- **S1: VoiceOver "Move forward / back" at a block end jumps onto the cross street, and can trap the car there.**
  - Where: `WPParkFlowController.nudge`, `nudgedCoordinate` (extends 5 m straight past the end, then re-snaps within 40 m).
  - What: on Lexington E, Madison E and W, Broadway W101-102 W and Broadway E10-12 E the next nudge after the last piece snaps to E 105th St, E 75th St, etc. (the cross street), a different street. Later "forward" nudges then walk along the cross street's polyline, and "back" does not return (probe: back ended 63 to 72 m from the block start). Stanton, Lexington W and Broadway E stop correctly at the end (5 of 10 side-blocks fail).
  - Expected: stop at the block end (spec).
  - Verdict stays honest for the curb it lands on (card shows the new street), so not a wrong-verdict, but the user is moved to another street unexpectedly.
  - Suggest: clamp the nudge to the same street and blockface (reject snaps whose street differs), and make "forward" mean a consistent direction along the street across sides.
  - Owner: `@ios-engineer`.
- **S2: per-frame redraw while a draft is pending.**
  - Measured on the sim (`top`, app process, map idle): pending 6 to 18% (about 12% average) of one core; no draft 0%. Stops immediately on Cancel (0%). Driven by `TimelineView(.animation, paused: phase != .placed)` re-running `tokenLayer` plus `pointForCoordinate` at display rate. It does run only while pending and stops when idle, as intended.
  - Impact: bounded to the pending card (seconds to a minute), not drive mode, so it does not explain R35-4 by itself, but it will add to lag on an older phone and drains battery if the card is left open. Recommend following up by driving updates from map region change plus a short display link only during gestures and the landing animation. Not blocking. Owner: `@ios-engineer`.
- **S3: "Not on a curb" only beyond 40 m** (see rule section). Product call; log for Kevin.

### Minor
- **M1: F1 incomplete where the facing piece overlaps under 5 m.** Up to a third of sampled avenue and Broadway pairs still draw a trapezoid. Consider clipping whenever there is any overlap, or choosing the pair by common span.
- **M2: the reveal reuses `recenterMap`** (resets zoom, and a rotated map). See deviation 4.
- **M3: AX5 pending.** The car is not visible at all. The verdict bubble is huge, overlaps the map strip and is clipped at the top ("midnight" cut), and the car sits under the bubble or card (`q15-ax5-pending.png`). The card is usable: street and side, Not saved yet, Cancel, Park here and Other side are all reachable and pinned. So placement can still be confirmed, but the user cannot see where the car is. Acceptable for ship; better to hide the bubble at AX sizes (the card already says it) so the car shows. Not hiding information (the card names street and side), but it hides the thing being placed.
- **M4: at default size the pending bubble sits over the street-cleaning pill** when the car is near the top (`q4-pending.png`). Cosmetic.
- **M5: with no card at AX5 the resting token floats over the goal sheet text** (seen at AX5 on home). Not verified whether pre-existing; the PR does not touch `showsRestingToken`. Likely pre-existing.

### Out of scope
- Street-cleaning pill overflows at AX5 home (DT35-8 family).

## Smoke (live sim, flags flipped locally and reverted)
- Home overlay layer renders (pill, search, More, Locate, goal sheet, you-dot).
- Tap curb, curb sheet, Park here: pending card with dashed "Not saved yet", dashed car on the curb, bubble above, "In front of 237 Chrystie St". `q3`, `q4`.
- Other side: car moves to the west curb, new verdict (Truck loading, red, "Park here anyway"), address 221. `q6`.
- Pan: map pans live, car stays glued to its ground point, bubble follows (car slips behind the card at the bottom, as expected). `q7`. Pinch not exercised (no pinch tool); pan only.
- Cancel: back to home, no parked car. Park here anyway: solid car on the same curb. `q8`.
- My Car "Wrong side? Switch" twice: 221 to 237 to 221 Chrystie.
- AX5: see M3, `q15`.

## What Kevin should check on a drive
1. Park here from a curb sheet: card says Not saved yet. Force-quit the app before tapping Park here: relaunch should show no car and no reminders.
2. Zoom in tight, drag the car along a long multi-piece block and across the street. The dot and bubble must always match the curb under the dot. Release between two curbs or over a building: it should land on the nearest curb. Drag well away: "Not on a curb".
3. Zoom in then drop near the bottom: does the map zoom out on landing (M2)?
4. Open the card and leave it for 30 s: does the phone warm or lag (S2)?
5. With VoiceOver, nudge forward along an avenue block to the end: it should stop, not move onto the cross street (S1).
6. My Car: Wrong side, Switch, Switch again: same address both ways.
7. Confirm the build flag script turns `driveModeDefaultEnabled` on, or you will still get one-tap save.
