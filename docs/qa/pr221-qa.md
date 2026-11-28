# PR #221 QA (DT35-2 park side, Stoop only)

**Reviewed:** `ios/dt35-park-side-pr1` at `7c25f849`, against `docs/specs/dt35-park-flow-and-drive-fixes.md` PR1.
**Verdict: FAIL (one blocking finding).** Everything else is good or follow-up.

## Summary
The resolver, ask card, picked card, Other side flip, hand (right/left) math and replaceSide are well built and the full suite passes (3265 pass, 0 fail, flags off). But the "other curb" is chosen with `CandidateSegmentSearch.oppositeSideCandidate`, which returns the FIRST same-pair segment on the other side. 94% of blockface sides in the bundled tiles are split into several pieces (Stanton Bowery-Chrystie has N_0..N_3 and S_0..S_3), so the "other curb" is an arbitrary piece, often 20-90 m along the street. On real Stanton tiles this makes the resolver CONFIDENT when the car is mid-street, which is exactly Kevin's rule violation (guess instead of ask). The builder's tests use single-piece synthetic curbs and cannot see it.

## Top-priority question: is the address hint swapped? NO, not a bug.
- Code: `ParkingAddressGeometry.probePoint` pushes 8 m toward the segment's compass side (math checked; N tile lines are north of S lines on Stanton). The hints are keyed by segment id and attached to the right buttons. `ParkingAddressGeometry` / resolver are untouched by this PR (identical on main).
- Ground truth, measured with Apple's own geocoder (CLGeocoder, from a throwaway script): reverse-geocoding 8 m north of the Stanton curb (Orchard-Ludlow) returns 96/100 (even); 8 m south returns 95/97 (odd). Forward geocoding agrees: 85 and 95 and 97 sit south of the south curb; 86, 96 and 100 sit north. Stanton St below Houston is odd = SOUTH. On 14th St it is odd = north (101 E 14th is north of 100), so the "odd = north" rule holds uptown but not here.
- Kevin's own report agrees: he parked on the south side "in front of about 15". Forward geocode puts 11 AND 15 Stanton (Bowery-Chrystie) on the south side, 15-18 m south of the south curb. So the builder's "South side near 85 / North side near 86" is correct. The log's "(north side)" for 11 Stanton was an assumption. Implication: on the field drive the saved side may actually have been south and the number off along the block, not a north snap. Worth a log line on the next drive (segment side + fraction).
- No test with a known blockface exists. Suggest adding one: Stanton Orchard-Ludlow, north probe must geocode even and south odd (needs a fake geocoder fixture plus a probe-latitude assertion); I did not find a PR test that pins probe direction for a real street.
- Parity validation is only "same as a prior verified address on the same segment+side". There is no cross-side parity check, by design (spec 3.2 says do not hardcode). Fine.

## Acceptance checklist
- [x] No verdict before a side is chosen: `showsVerdict` false in ask; live ask screenshot shows no verdict; tests present.
- [x] Never breaks a tie by GPS-nearest: ask buttons ordered by hand/compass, not distance. But see finding 1 (the pair itself is wrong).
- [x] Right/left math: cross product in east/north, checked by hand (travel north, curb east = right). One-way and two-way both use the retained approach course; rotation tests exist. Not drive-verified.
- [x] Other side flips and flips back (model test, live flip observed).
- [x] My Car "Wrong side? Switch": `replaceSide` keeps id/parkedAt/notify, drops address, no pinDropped; `forgetAttempts` cancels the in-flight address task and `cancelAllThenSchedule` cancels the prefix then schedules in the same callback, so no duplicates/orphans by reading. Not exercised live (needs a saved car + notification permission).
- [x] Flag-off identical: all new UI paths gated on `designSystemV2Enabled`; `LocationService` now records fixes in both flag states (in-memory only, no behaviour change). 3265/0 flags off.
- [ ] Confident-or-ask on real multi-piece blocks: FAILED, finding 1.

## Findings

### Blocking
- **#1: "Other curb" is an arbitrary piece of the opposite side, so Stoop guesses or shows a misaligned pair**
  - Where: `ParkSideResolver.decide` / `switched` -> `CandidateSegmentSearch.oppositeSideCandidate` (exact-pair branch uses `segments.first(where:)`).
  - What: with real tiles (Stanton Bowery-Chrystie, car placed exactly between the true curbs, accuracy 8 m): N_1 -> ASK but second = S_0, 20 m away; N_2 -> CONFIDENT N_2 (opposite chosen S_0 at 55 m, so z is huge); N_3 -> CONFIDENT S_3 (opposite S_0 at 89 m). Same result with reversed tile order. `switched` moves the car 20 m / 55 m / 89 m along the street, and the verdict shown is for that piece's signs. Live sim at Stanton Orchard-Ludlow: the chooser mini-map draws the south curb shifted ~20 m left of the north curb (a parallelogram), "South side near 99" is a different building than where the car is, and Other side gave a different legal verdict. Screenshot: `docs/qa/pr221-assets/ask-misaligned-curbs.png`. Data check: 3,117 sampled pieces, first-opposite is more than 20 m farther than the true opposite in 51%.
  - Expected: never-guess. B must be the opposite-side piece that actually faces the car (min distance to the stopped position / overlapping along the axis), among same-pair pieces; `switched` the same.
  - Repro: `docs/qa/pr221-assets/QA221RealTilesProbeTests.swift.txt` (drop into WeParkTests, run). Prints the lines above.
  - Owner: `@ios-engineer`. Fix in the Stoop path (do not change legacy `oppositeSideCandidate` callers); add real-tile or multi-piece fixture tests for decide, switched, `FlowController.oppositeSnap`, and My Car `refreshSideTarget`.

### Significant
- **#2: Ask hint address is for the chosen (wrong) piece** until #1 is fixed; re-verify after the fix that "near N" is computed at the car's along-street position.
- **#3: Flag-on failures not re-proven on main.** The builder's 34 failures; the names I could extract from the builder's log (20 unique) are flag-default guards (`testFlag_defaultsFalse`, `...flagOff...`, notification category registry, Clip, etc.). I did not build main with the flags flipped, so I cannot confirm each fails identically there. Not verified.

### Minor
- weakFix "Place it on the map" ends Drive Mode with nothing saved. Acceptable, but a driver mid-trip loses Drive Mode; consider a label like "Place it on the map (ends Drive Mode)". Deviation 4: accepted.
- The ask hint text "Tap a curb on the map" is read by VoiceOver while the map is hidden from it. Buttons carry full labels (live label confirmed: "This side, north side, near 100 Stanton Street").
- AX5 and VoiceOver walkthrough not run by me beyond the label check; builder's AX5 header fix not re-inspected.

### Out of scope
- DT35-7 etc. untouched.

## Builder deviations
1. Keep `findCandidateSegments` dedupe, use `oppositeSideCandidate`: dedupe kept is right; `oppositeSideCandidate` is the wrong tool for pieces (finding 1).
2. Approach bearing from moving fixes within 60 m: reasonable; not drive-verified.
3. "This side" title with compass/address caption: fine.
4. weakFix ends Drive Mode: accepted (minor note).
5. No map highlight of chosen curb: accepted for PR1.

## Tests / smoke run
- Full `WeParkTests`, flags off, PR head, `-parallel-testing-enabled NO -jobs 4`: 3265 passed, 0 failed, 1 skipped. (First attempt hit "test runner hung before establishing connection" under host load, rerun clean.)
- Throwaway real-tile probe test (above), passes while printing the failing behaviour. Not committed to the test target.
- Sim `wepark-qa221-sim`, flags flipped locally (StoopFlag, address-anchored, drive default; reverted, never committed): drive mode renders; checklist appears; weakFix card on a stale fix ("Waiting for a better GPS signal", Try again, Place it on the map); ask chooser with fresh fixes at Stanton ("This side" x2 because simulator has no course); picked card; Other side flip. Right/left wording, AX5, My Car Switch and real approach heading were not exercised (no course in the simulator, no saved-car run).

## What's working
Never-ask-nothing flow reads well, big targets, honest weakFix, clean `replaceSide` (same id, no pinDropped, address task cancelled), hand math and rotation invariance tests, flag-off suite green.

## Kevin: check on a real drive (after finding 1 is fixed)
1. Park on Stanton mid-block on a block with several sign pieces; the ask map must show two aligned curbs facing each other, and neither button may move the car along the block.
2. Check which house number is in front of you (Stanton: odd = south). The hint on each button must match the building on that curb.
3. Right/left: drive in one-way, tap Park here, "Curb on my right" must be the curb on your right.
4. Pull in, then Other side, then back: car returns to the same spot; verdict follows the side.
5. My Car, "Wrong side? Switch": same car, new address, exactly one set of reminders (check the pending notifications).
6. Hold GPS poor (garage exit): weakFix, nothing saved.

---

# Re-verification (QA pass 2) — head `4b15e385`

**Verdict: PASS with follow-ups.** The blocker is fixed. No new blocking findings.

## Diff scope (item 7)
`git diff b75f1716..4b15e385` touches exactly two files: `Services/ParkSideResolver.swift` (+60/-10: new `facingOpposite`, used by `decide` and `switched`) and the new `WeParkTests/ParkSideMultiPieceTests.swift`. Legacy `oppositeSideCandidate` is unchanged and its only remaining caller (`ContentView.swift:7451`) is the legacy path. All Stoop call sites (`WPParkSideLogic`, `WPParkFlowV2.oppositeSnap`, `WPMyCarV2View.refreshSideTarget`) go through `switched`. Flag-off: no non-Stoop code changed; full suite flags off passes (below).

## Independent probes on real tiles (items 1-2)
Probe: `docs/qa/pr221-assets/QA221bSweepProbeTests.swift.txt` (throwaway, not committed to the target). Ground truth is independent of the resolver: the facing piece is the opposite-side piece whose along-street interval (on the car-side piece's axis) contains the car; checks run on all ~47.7k Manhattan segments.

- Original Stanton Bowery-Chrystie N_1/N_2/N_3 probe, both tile orders: now ASK/pair with the facing S piece; no confident-at-55 m. (Builder's test and live sim agree.)
- Named blocks (not the builder's fixtures), 3 car positions per piece, flip/flip-back, decide: Lexington Ave E105-106 (N-S avenue, 6 pieces), Madison Ave E74-75 (4/3 pieces), Amsterdam Ave W72-73 (4/5), Avenue A E11-12, Broadway W101-102 (curved), Broadway E10-12 vs W10-11 + W11-12 (cross-street labels DIFFER between sides), Canal Hudson-Renwick vs Hudson-Watts (labels differ). Result: 0 wrong pieces, 0 along-street jump over 25 m, 0 confident-with-far-piece, 0 misaligned asks. Only oddities are on Canal (tiny 4 m pieces and a diagonal street): flip-back landed on the adjacent piece 1 m away twice, and one tiny piece has no switch (graceful onlyCurb).
- Sweep, 1 in 20 multi-piece blocks (5,119 car positions): confident-with-far-piece **0**, misaligned ask **0**, switch jump over 25 m **0** (max 8 m). 70 "different piece than my nearest-truth" cases, all within 8 m along-street; they are overlapping pieces (1st Ave, Riverside Dr service roads, Park Ave median, Delancey/Broome) where the resolver prefers the same-cross-street piece, which is the intended rule.
- Flip-and-return at the stored-option level: card model keeps both options, so exact; verified live below. Re-projection flips (My Car "Wrong side? Switch" twice, which re-projects from the live car each time) return to the same piece in most cases but drift 1-11 m or land on the adjacent piece in 288 of 5,119 sampled cases (5.6%), mostly where the two sides' labels differ. Not unsafe (still the facing curb) — see follow-up F2.
- Block ends (9,596 positions at 0, 3, 97, 100% of a piece): 546 nil (no switch offered, graceful), 55 "far" cases, all but a few are same-block pieces clamped at the other side's end (8-11 m) in short-piece data; a handful (St Nicholas Ave, Riverside Dr W158, 2nd Ave E124, Stone St) pick a different-block piece 25-50 m along on the loose-label path with the car AT a curb end, where decide still goes confident on the near curb, so no wrong verdict. It never picked the next block's piece when a same-cross-street counterpart existed.
- One-piece side / side with no pieces / angled street: covered by builder's `testNoParallelOrNoNearbyPiece_returnsNil` plus sweep nils; Broadway W101-102 curved block clean.

## Address hints (item 3)
Live sim, Stanton Bowery-Chrystie N_2 car, ask card shows "North side - near 10 Stanton St" and "South side - near 15 Stanton St". Picked card: "In front of 10 Stanton St, North side"; Other side shows "In front of 15 Stanton St, South side"; Other side again returns "10 Stanton St, North side". So the hint is for the facing piece at the car's along-street position, matches the earlier ground-truth (even north, odd south, ~15 south as Kevin parked), and flip/flip-back is exact. Screens: `rev-ask-card.png`, `rev-side-north.png`, `rev-side-south-after-flip.png`, `rev-side-back.png`.

## Tests (items 4-5)
- Full `WeParkTests`, shipped flags, PR head, `-parallel-testing-enabled NO -jobs 4`: **3277 tests, 1 skipped, 0 failures** (no flakes hit).
- Flags flipped locally (StoopFlag, driveModeDefault, curbPin, addressAnchored, myCarSheetV2), PR head: 3277 run, **34 failure lines = 23 unique tests**, all flag-default/registry guards (e.g. `DesignSystemV01Tests.testFlag_defaultsFalse`, `NotificationCategoryRegistryTests`, `ClipFlowControllerTests.testArm_*`, `StoopPhase6aTests`).
- Same flips on `origin/main` (`20ffe8f6`), only those 17 test classes: 281 tests, **34 failure lines, 23 unique, name-for-name identical** (`diff` clean). So the 34 are pre-existing (they assert the shipped defaults), not caused by this PR. Resolves old finding #3.

## Sim smoke (item 6)
Own sim `wepark-qa221b-sim` iOS 26.5, flags flipped locally, never committed.
- Home map at Stanton shows both curbs aligned (green lines parallel).
- Drive Mode, Park here, sign checklist, then with fresh fixes the **ask** card (not weak, not confident) with mini map and two "This side" buttons: `rev-ask-card.png`.
- Pick, Other side, Other side: 10 -> 15 -> 10 (above).
- AX5 (accessibility-XXXL): side card header and Cancel intact, sheet scrolls to Park here and Other side (`rev-ax5-side-card.png`, `rev-ax5-side-card-scrolled.png`); ask chooser header wraps, Cancel intact, buttons wrap (`rev-ax5-ask-chooser.png`).
- Not exercised: right/left wording (simulator has no course), My Car Switch, token confirm card, real motion.

## Remaining findings
- **F1 (minor, visual): the ask mini-map still draws a trapezoid on multi-piece blocks.** On Stanton N_2/S_2 the north line spans the full piece and the south line starts ~12 m late and ends ~2 m early, joined by a diagonal fill. It is data-faithful (the two sides' pieces have different extents) but not "aligned". Suggest clipping both lines to their common along-street span. Owner `@ios-engineer`. Not blocking; the pairing and hints are right.
- **F2 (minor): My Car "Wrong side? Switch" re-projects each time**, so flipping twice can drift 1-11 m or land on the adjacent piece (5.6% of sampled cases, mostly differing-label blocks). Card/token flows hold stored options and are exact. Optional: remember the original option for one flip-back.
- **F3 (minor): block-end clamp** can pair a curb up to ~10 m along-street from the car where the other side's piece ends early; no wrong verdict seen.
- Earlier finding #1: **resolved**. #2: **resolved** (live). #3: **resolved** (above).

## Kevin must check on a real drive
1. Stanton Bowery-Chrystie, park mid-block on the south side: ask card names near 15 (odd) vs near 10 (even); pick the side you are really on and confirm the verdict matches the signs you see.
2. Park near a block end/intersection and at an avenue (Lexington/2nd Ave): the card must still offer both sides of THIS block and never a curb up the next one.
3. Real approach heading: "Curb on your right/left" wording (needs real course; simulator cannot test).
4. Other side flip: the other curb should be directly across from the car (look at the mini map; a small trapezoid skew is known, F1).
5. My Car after saving: "Wrong side? Switch" then switch back; check the address and verdict return to what you started with (F2 drift).
6. A one-way street and a street with a median (Park Ave, 1st Ave tunnel stretch, Riverside Dr): ask vs confident should feel sane and never place you on a service road you are not on.
