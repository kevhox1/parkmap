# PR #226 QA (DT35-3 follow-ups: S1 nudge, S2 timeline, S3 drag reach, minors, F1)

Reviewed: branch `ios/dt35-3-followups` at `8fcde458`, against `docs/qa/pr224-qa.md`. QA agent did not build this. Own sim `wepark-qa226-sim` (iOS 26.5), flags flipped locally for the live smoke and reverted, sim and derived data deleted. Nothing pushed except this report and its assets.

**Verdict: PASS with follow-ups.** S2, S3, the minors and F1 hold. S1 mostly holds (no walk ever left its blockface in about 800 real-tile walks), but I found one new defect in the S1 fix: at some piece junctions the nudge stops making progress and keeps saying "moved", so the car is trapped mid-block (about 3 of 83 sampled multi-piece blocks). Not a blocker (VoiceOver-only path, behind two dark flags), but it should be fixed before VoiceOver users rely on it.

## Results

| Area | Result |
|---|---|
| Full `WeParkTests`, shipped flags (all off), PR head, `-parallel-testing-enabled NO -jobs 4` | 3377 run, 1 skipped, 0 failures. No flakes hit. |
| Dry-run merge vs `origin/main` (`3dbd7c93`) | Clean (`git merge-tree --write-tree`, no conflict). |
| Dry-run merge vs PR #223 (`ios/dt35-6-legal-label`) | Clean at text level. Both touch `MapViewRepresentable.swift` in different regions (this PR: Coordinator seam properties near line 967, `panToCenter` next to `screenPointForCoordinate`, a new delegate method near 3183; #223 adds the bottom-inset work). The combined tree was not compiled. |
| Live smoke (flags flipped locally) | Home overlay layer renders (pill, search, More, Locate, goal sheet, you-dot): `docs/qa/pr226-assets/home-overlay.png`. |

## Acceptance checklist

- [~] S1 stays on blockface, stops with "End of block": never leaves the blockface (0 strays), stops at the real end on 8 of 8 named blocks, but see finding #1 (stuck at a junction on some blocks).
- [x] S2 no per-frame timeline; idle CPU about 0%: measured below.
- [x] S2 seam removed after Cancel / Park here / Drive Mode: code-verified, Cancel also CPU-verified live. Backgrounding: see note.
- [x] S2 delegate forwarding is a no-op with no draft: pan CPU identical with and without a draft.
- [x] S3 10 m reach, 12 m hold, "Not on a curb" beyond: probed, table below.
- [x] S3 wide-avenue parking lane still snaps; hysteresis leaves no stale verdict.
- [x] Minor: bubble hidden at AX, pan-only reveal, bubble below car near the pill, F1 small-overlap.
- [x] Changed old test still tests something (weaker than before, see nit).

## S1 on real tiles (own test, full flow: `enterPending` then `nudge(5)`, all 47,696 Manhattan segments loaded)

Files: `docs/qa/pr226-assets/QA226Tests.swift.txt`, `QA226TraceTests.swift.txt`. Not the builder's fixtures: the whole tile set is loaded so cross streets compete, every piece of each block is a start, both directions, then the opposite direction from wherever it stopped ("back must return"). Checks: every landing is on the same street, side and cross-street pair; "End of block" arrives within 120 steps; the stop is within 3 m of a real block end; back ends at the other end.

- **Named blocks** (both sides): Lexington E105-106 (E, W), Madison E74-75 (E, W), Broadway W101-102 (E, W), Broadway E10-11 and E11-12 (W side in the data), plus 3 extras by choice: Park Ave E112-115 (E, W, 13 pieces each), W 72nd St (N Amsterdam-Columbus, S Riverside-West End), West End Ave E and W 66-70 (10 to 11 pieces). 188 walks.
  - Strays onto a cross street or other side: **0**. Stopped short of the end: **0**.
  - **Stuck: West End Ave E 66-70 only**, 3 forward walks and 11 back walks never reach "End of block" (see #1).
- **Sweep**: 69 further multi-piece blockfaces (every 150th, sorted), 618 walks. Strays 0, short of end 0, back-fail 0, **stuck 11 walks in 2 blocks** (2nd Ave W E61-62, Cabrini Blvd E W187-190).
- The 5 originally failing side-blocks (Lexington E, Madison E/W, Broadway W101-102 W, Broadway E10-12) all now walk to the end and back cleanly. Note the Broadway E10-12 labels differ by side in the data, so it is walked as separate blockfaces per side.

## S2 CPU (sim, app process, `top`, 2 s samples, map idle unless noted)

| State | CPU |
|---|---|
| Draft pending, idle (6 samples) | 0.0, 0.5, 0.1, 0.0, 0.1, 0.0 % (was about 12%) |
| After Cancel, no draft (3 samples) | 0.0, 0.0, 0.0 % |
| Panning with a draft pending (5 samples, scripted swipes) | 24.0 to 29.7 % |
| Panning with no draft (5 samples, same swipes) | 23.9 to 28.1 % |

The seam adds nothing measurable to a pan. The car stays glued to its curb after a pan (`pending-after-pan.png`: car on the Bowery west curb line, bubble above, no overlap).

Seam lifetime. `onVisibleRegionMoved` is set in `.onChange(of: v2ParkFlow.phase)` to `{ mapMoved() }` only for `.placed`, else nil. Cancel, Park here (`commit` then `reset`) and Drive Mode entry (`onChange(driveModeActive)` calls `reset`) all end in `.idle` and clear it. `mapMoved()` also guards on `phase == .placed`, so a stale closure would still be inert. It is nil during `.dragging` (the car follows the finger there) and reinstalled on landing or restore. Backgrounding does not reset the draft (existing behaviour), so the seam stays installed while the app is backgrounded; it fires only on map frames, so cost is zero. Not verified live: Drive Mode entry and backgrounding (I did not drive them; code path only).

Delegate forwarding: `mapViewDidChangeVisibleRegion` is a single optional-chained call to a nil closure with no draft. No other delegate behaviour changed. Home overlay layer still renders after the change (screenshot).

## S3: where "Not on a curb" appears

Probe: finger at distance d from the chosen curb line, perpendicular, fresh drag, toward the street and away from it (building side). Files `s3-probe-output.txt`, `QA226S3Tests.swift.txt`.

Important data fact (`curb-gap-histogram.txt`): the tile curb lines are class-width, not surveyed. Facing-curb gap is 12 m for about 3,700 of 5,000 sampled pieces (all ordinary streets), 20 m for avenues (Lexington, Madison, Broadway, W 14th, W 34th, W End), and 25 to 34 m on Park Ave, Houston and Canal in places.

| Street (gap) | 0 / 5 / 9 m | 11 / 13 / 20 m | 30 m |
|---|---|---|---|
| Narrow, E 74th (12 m), building side | curb verdict | NOT ON CURB | other street's curb (9.9 m from it) |
| Narrow, E 74th, street side | own curb 0/5, opposite curb 9 (3 m from it) | opposite curb | NOT ON CURB |
| Avenue, 20 m gap (Lexington, Madison, W 72nd, Park, Broadway, W End), building side | own curb at 0, 5, 9 m | NOT ON CURB at 11, 13, 20, 30 | NOT ON CURB (one W End case snaps a nearby cross street) |
| Same, street side | own curb to 9 m, then the opposite curb (9, 7, 0 m) | opposite curb | NOT ON CURB |

- So: building side flips between 9 and 11 m (reach 10); street side never shows "Not on a curb" on 12 m and 20 m streets because every point is within 10 m of one curb. On the real wide spots (gap above 20 m: Park Ave to 31 m, Houston to 34 m) a band of roughly gap minus 20 m in the middle is "Not on a curb"; the builder flagged this trade-off and I agree it is the intended outcome.
- Parking lane of a wide avenue: car on the avenue's curb line (0 m) and 5 to 9 m out toward the building still snap to the correct side. Legitimate parked cars snap. Because the data curb is a model, a real curb on Park Ave or Houston that is more than 10 m from the data line will say "Not on a curb"; worth a drive check.
- Hysteresis (acquire at 3 m, walk away, building side, on all 7 probed streets): verdict holds to 11.9 m, gone at 12.1 m; coming back in at 11.0 m stays "none" and re-acquires at 9 m. No stale verdict persists, and the 12 m hold does not self-extend. One caveat of the 12 m hold: a spot 10 to 12 m from the curb still shows a verdict for up to 2 m beyond the 10 m rule while dragging out. Acceptable.
- One odd case: West End Ave E probe at 20 to 30 m building side snapped the cross street N at 8.4 m (it is near a corner). That is a different curb that is genuinely within 10 m, so correct.
- Entry rule: `placeAt` (Park here entry, GPS) uses `entrySnapConfig` (40 m), unchanged; covered by the builder's test and by code.

## Minor items and F1 (live and code)

- **Bubble hidden at AX**: AX XXXL with the car pending (`ax-pending-no-bubble.png`): no bubble, car visible above the card, "Not saved yet" and the street are in the card. The off-curb note is announced via `UIAccessibility.post` on `.dropOnCurb`.
- **Bubble below car near the pill**: `bubbleCenterY` returns below the car when the above position would be under y 170 (builder's screenshot; unit-tested). Not re-driven by me.
- **Reveal pans only**: `v2RevealPendingCar` now calls `panToCenter` (`setCenter(animated:)`), which does not reset zoom, heading or pitch. Not exercised live by me (needs the car dropped behind the card); code-verified, and the AX screenshot is consistent with a pan, not a re-zoom.
- **F1 remainder**: both curbs drawn over the car's piece span when overlap is under 5 m (`carCurbSpan` plus `extend`). The new test checks every real facing pair in the 5 QA blocks draws aligned (more than 20 pairs). The drawing invents the shorter curb's extension along its own end direction. It is schematic, but the other curb is drawn longer than it really is.
- **Changed old test** (`testBarelyOverlappingCurbs_areDrawnOverTheCarsPieceSpan`, renamed): previously asserted only point counts. Now asserts the two curbs have equal start and end x. That tests the visual alignment goal, but does not assert which span (the car's piece, 0 to 50) is chosen; a regression to the common span would still pass. Nit.

## Findings

### Blocking
- none

### Significant
- **#1: VoiceOver nudge gets stuck at some piece junctions and keeps saying "moved".**
  - Where: `WPParkFlowController.nudgeTarget` (past-end branch) with `nudge`/`placeAt`.
  - What: at a piece end where the next piece of the same blockface starts at the same point but turns, the projection of `beyond` onto the next piece can be its start point. The "genuinely further on" test is `>= distanceToEnd - 0.5`, which is trivially true when `distanceToEnd` is 0, so `.move(sameCoordinate)` is returned. `placeAt` then re-snaps with the incumbent dead-band and stays on the old piece at fraction 1.0. The result is `.moved` forever, no progress, no "End of block". Trace on West End Ave E 66-70: piece E_2 (10 m) to E_3, steps 9 to 39 all at `40.776538,-73.986733`, frac 1.000, result `.moved`. The same junction traps the back walk from E_3 onward.
  - Rate: 3 of 83 sampled multi-piece blockfaces (West End Ave E 66-70, 2nd Ave W E61-62, Cabrini Blvd E W187-190). Both directions through the trap junction fail.
  - Expected: advance onto the next piece, or say "End of block" only at the true end.
  - Repro (test): `QA226TraceTests.testTraceWestEnd`, or in the app with VoiceOver, pending car on West End Ave east side near W 67th, "Move forward" repeatedly.
  - Effect: user can't move the car past that junction with VoiceOver and gets no useful announcement. Drag is unaffected.
  - Owner: `@ios-engineer`. Suggested fix: require the successor foot to be at least about 1 m beyond `here` (or put the car at `fraction` on the successor from a distance measured along it), and add a regression test that walks every real multi-piece block to the end, not just 4 blocks and not just from the first piece.

### Minor / nit
- **#2:** Builder's flow test `testFlow_nudgeToTheEnd_neverLeavesTheStreetAndSide` only walks forward from `group.first` on 2 streets, which is why #1 was missed. The pure walk test passes because it picks each landing's piece by itself.
- **#3:** Changed old test is weaker on which span is chosen (above).
- **#4:** At AX XXXL the street-cleaning pill and goal sheet crowd the map (already tracked as the DT35-8 family; not part of this PR).

### Out of scope (logged)
- Curb data is class-width (12 m / 20 m), not surveyed. Any future reach tuning is a product call against real curbs (Houston, Park Ave median). "Not on a curb" in the middle of Park and Houston is by design.
- Backgrounding keeps the pending draft and the seam. Harmless.

## Smoke tests run
- Full `WeParkTests`, flags off: 3377 run, 1 skipped, 0 failures.
- Own real-tile S1 sweep: 188 named plus 618 sampled walks.
- Own S3 probe on 7 streets (narrow, avenue, wide) at 0, 5, 9, 11, 13, 20, 30 m, both sides, plus hysteresis walk.
- Live: build, install, launch, home overlay screenshot read; tap curb, Park here, pending card, CPU idle / pan; Cancel then idle CPU; AX XXXL pending with car visible and no bubble.
- `git merge-tree` dry runs vs main and #223.
- Not verified: Drive Mode entry and backgrounding live; pinch and the "reveal behind the card" pan live; compile of the #223 plus #226 combined tree.

## What's working
- S1 never leaves the blockface (0 strays in about 800 walks on real data), including all five previously failing side-blocks.
- S2 is a real fix: 12% to about 0% idle, pan cost unchanged, seam lifecycle tied to phase with a second guard in `mapMoved`.
- S3 does exactly what the rule asks: no verdict from 11 m off the curb, clean 12 m hold, nothing stale, parking-lane positions still snap, entry rule unchanged.
- Minor items are tidy and unit-tested; AX layout now keeps the car visible.

## What Kevin should check on a drive
1. Pending card: pan and pinch the map; the car should stay on its curb with no lag or heat. Leave the card open for a minute and check the phone does not warm up.
2. Drag the car onto a building or the middle of a wide road (Park Ave, Houston): bubble should say "Not on a curb" and release should go back to the last curb. Drag it onto a car-width spot on a real avenue's parking lane: it should still snap. If a real Houston or Park curb says "Not on a curb", the 10 m reach is too tight (the builder offered 12 to 14 m).
3. Drop the car near the bottom of the screen so the card would cover it: the map should slide the car up without changing zoom or rotation. Drop it near the top: bubble should go under the car.
4. VoiceOver (if you test it): "Move forward" on West End Ave east side around W 67th may stall (finding #1); on ordinary blocks it should end on "End of block".
5. Large text: the car stays visible, no bubble, street and verdict in the card.
