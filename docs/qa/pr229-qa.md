# PR #229 QA (DT35-3 nudge walks the block's pieces)

Reviewed: branch `ios/dt35-3-nudge-trap` at `64ecd534`, against `docs/qa/pr226-qa.md` finding #1. QA agent did not build this. Own sim `wepark-qa229-sim` (iOS 26.5), own derived data; both deleted at the end. Only this report and its assets are pushed. Test file: `docs/qa/pr229-assets/QA229Tests.swift.txt` (not added to the target).

**Verdict: PASS with follow-ups.** The 3 reported blocks are fixed, the E 79th St hook walks cleanly, no walk in about 63,000 ever left its blockface or moved less than 0.5 m, and no walk stopped away from a true end. The full suite is green. But my wider sample found two remaining ways a walk never reaches "End of block": a direction flip on a curved block (Paladino Ave) and a ping-pong against short overlapping stub pieces (Bowery W, Broadway E W125-126). Both sit behind the dark VoiceOver flags and hit about 0.1% of blockfaces by a strict count. Fix before VoiceOver users rely on it, not a blocker.

## Acceptance criteria

- [x] 3 reported blocks no longer trap (West End Ave E W66-70, 2nd Ave W E61-62, Cabrini Blvd E W187-190): walked from every piece at 0, 0.5, 1.0, both ways, 0 bad, 0 end spread. See table.
- [x] E 79th St doubling-back hook keeps walking: all 16 E 79th St multi-piece blockfaces (both sides, every cross-street pair) end at one true end both ways, 0 bad.
- [x] Never leaves the blockface: 0 strays in 62,640 pure walks and 978 flow walks.
- [x] Every step moves at least 0.5 m: 0 short steps in 62,640 pure walks.
- [x] Ends at a true end: "stopped away from a true end" = 0. (Blocks whose end I could compute: ext ends == 2.)
- [ ] Ends within a bounded number of steps: FAILED on 3 blocks (finding #1, #2).
- [ ] Same end for forward from every piece, opposite end for back: FAILED on 19 of 2387 blockfaces; 3 are explained by findings #1 and #2, the rest are probably data (see #3).
- [x] Forward then back returns close: max drift 4.5 m (3 out, 3 back, 5 m steps), see below.
- [~] Forward is stable on a curved street: FAILED on Paladino Ave (finding #1); held on Riverside Dr (104 blocks), Central Park West, St Nicholas Ave, Fort Washington Ave, Cabrini.
- [x] VoiceOver announcements through `nudge`: 0 "moved" that did not move, 0 "End of block" that changed state, "End of block" sticky when repeated.
- [x] Full `WeParkTests`, shipped flags: 3393 run, 1 skipped, 0 failures.
- [x] Dry-run merge against latest `origin/main` and `origin/ios/dt35-6b-drive-stack-ax` (PR #228): `git merge-tree --write-tree` both clean, no conflicts.

## What I ran

Own test (not the builder's sample), real tiles, all 47,696 segments, blockface = (street, side, from, to) exactly as `isSameBlock`.

- **Sample:** 10,300 multi-piece blockfaces. Every 7th starting at index 3 (1,471) plus every multi-piece blockface on 11 named streets: Amsterdam Ave (201), Broadway (380), Columbus Ave (81), Riverside Dr (104), St Nicholas Ave (125), Fort Washington Ave (44), Central Park West (59), Bowery (24), East End Ave (18), W 4th St (23), Cabrini Blvd (10). Total 2,387 blockfaces. ("FIRST/SECOND/THIRD AVENUE" do not exist in the data; they are "1ST AVENUE" etc., covered by the offset sample only.)
- **Pure walk** (`nudgeTarget` loop, 5 m steps, up to 400): from every piece, at fraction 0, 0.5 and 1.0, forward and back: 62,640 walks. Checks: same street/side/from/to for every landing, at least 0.5 m between landings, ends within 3 m of a true chain end, all forward walks end at one place, all back walks at one place and not the same as forward.
- **Out and back:** from mid-piece, 1 and 3 steps out and the same back, both signs.
- **Flow through `nudge`:** `enterPending` with all segments, then `nudge`. 163 blockfaces (every 7th starting at 3, then every 60th of those, plus all West End Ave, Cabrini, E 79th St, Paladino, Bowery, Broadway E W125-126), first/middle/last piece, both ways, 978 walks. Checks: result is `.moved` only if the coordinate changed at least 0.5 m, `.endOfBlock` only if state is unchanged, repeating gives `.endOfBlock` again, stays on the blockface, within 3 m of a true end.

### Results

| Check | Result |
|---|---|
| Pure walks | 62,640; strays 0; steps under 0.5 m 0; stopped away from a true end 0; no end in 400 steps: 75 walks in 3 blockfaces |
| Forward/back end consistency | 19 of 2,387 blockfaces with different ends by start piece (3 are the no-end blocks above) |
| Max out-and-back drift | 4.5 m, `BROADWAY W Thames St - Rector St`, 3 steps out/3 back, back direction. Others under that. |
| Flow | 978 walks; moved-without-moving 0; End-lies 0; strays 0; no-end 12 walks; inconsistent forward end 2 blocks (Paladino E and W) |
| Full suite | 3393 run, 1 skipped, 0 failures; location denied log noise only, no reset needed |

Original 3 plus the hook (all pieces, 3 fractions, both ways, `testNamedOriginals`): every row `bad 0`, `endSpread 0`, `endToTrueEnd 0` (`docs/qa/pr229-assets/named-output.txt`).

| Block | Pieces | Max steps | Result |
|---|---|---|---|
| West End Ave E W66-70 | 11 | 58 | OK |
| 2nd Ave W E61-62 | 3 | 13 | OK (one-ended chain, ext 1) |
| Cabrini Blvd E W187-190 | 8 | 42 | OK |
| Cabrini Blvd E W181-187 | 16 | 98 | OK |
| 16 E 79th St blockfaces (hook included) | 5-10 | 27-49 | OK |

## Findings

### Significant (follow-up)

- **#1: "Forward" flips on a curved block, so the car ping-pongs and never gets "End of block".**
  - Where: `WPParkFlowController.nudgeTarget`, `isReversed(_:)` and `along` at the start of the walk.
  - What: the reference direction is the sum of the pieces' unit directions, then each piece is "reversed" if its own direction has a negative dot with that sum. On a block that bends enough, a piece at one end (a piece more than 90 degrees off the overall heading) is classed as reversed even though it is digitised the same way as its neighbours. The starting piece's sign then disagrees with the sign the walk used when it crossed onto it from the neighbour, so the next call turns around. PALADINO AVENUE E, E 120th St - 1st Ave (13 pieces, bends from NE to WNW): piece E_0 is "reversed".
    - Back from E_1@36: `E_1@23, E_1@10, E_0@89, E_1@10, E_0@89, ...` forever (trace in `QA229Tests.swift.txt`, `testTrace`).
    - Forward from E_0 at 0%: `END` immediately, though the block runs 500 m on.
    - Back from E_0@50: `E_1@0, E_0@50, E_1@0, E_0@50, ...` (moves 3 to 5 m each time, "moved" every call, no end).
    - Same on Paladino W. 75 of 62,640 walks, 3 blocks in this sample, "forward end differs by start piece" on both Paladino sides in the flow test.
  - Expected: one direction for the whole block, stable on bends, and "End of block" at the start of the block when walking back.
  - Repro: the pure `testTrace` above, or in the app on Paladino Ave east side, "Move back along the block" repeatedly near E 120th St.
  - Suggested direction: decide the sign once per block from the chain itself (walk the chain order from a true end), not from the dot of each piece with a global sum; or carry the direction in the step result (it already knows `along`).
  - Owner: `@ios-engineer`

- **#2: Short stub pieces that overlap the main piece make the walk bounce between two points.**
  - Where: `nudgeTarget`, next-piece pick (6 m join tolerance and `best < metersBetween(touch, behind)`), `visited` is reset on every call.
  - What: a 3 to 5 m spur at the end of the block is joined by the 6 m tolerance to the main piece's end, and the main piece to the spur's start/end, so every call goes main -> spur -> main. Each step moves at least 0.5 m so the new guarantee "moved means moved" holds, but "End of block" never arrives. BOWERY W Canal - Bayard (W_5, 5 m stub): `... W_4@96, W_5@27, W_4@96, W_5@27 ...`. BROADWAY E W125 - W126 (E_2, 3.9 m stub): `E_1@97, E_2@0, E_1@97, E_2@0 ...`. Forward only, from every piece (Bowery 6 pieces x 3 fractions forward fail, same for Broadway E).
  - Effect: the car does sit at the true end, but VoiceOver keeps saying "moved" and the car jitters instead of "End of block". Same class as the original finding but the car is not stuck mid-block.
  - Expected: "End of block" once the car is at the end.
  - Owner: `@ios-engineer`

### Minor / nit

- **#3:** 16 more blockfaces in my sample had forward or back ends that differ by start piece (Amsterdam Ave W66-70, Bennett Ave, Broadway W W218-Isham, Marketfield St, Broadway W Grand-Howard, and others). 128 blockfaces have other than 2 chain ends (disconnected pieces, or one-ended chains like 2nd Ave W E61-62), so a walk can only reach the end of its own connected run. I looked at the numbers, not the geometry, for these. Not verified whether each is data or the same cause as #1/#2; the report log is cut at 80 lines (`pure-walk-output.txt`). Worth rerunning the property test over all of them once #1 and #2 are fixed, and asserting by connected component.
- **#4:** Drift of up to 4.5 m on out-and-back (Broadway W Thames-Rector) is real but small; likely a curved or hooked piece. No action.
- **#5:** The builder's property test passed 1,470 blocks; mine fails on Paladino/Bowery/Broadway that are in the data. The existing assertion is probably checking per-step progress rather than ending. Add "ends within N steps from every piece, both ways, ends consistent" as hard assertions.
- **#6:** Each `nudge` still filters all `knownSegments` (47,696) with `isSameBlock` and does `oppositeSnap` over all of them, about 20 nudges per second in the sim under load. Fine for a human tapping a button, slow for a long property test (my flow test took 18 minutes for 978 walks).

### Out of scope (logged)
- Data: duplicate or spur pieces at block ends (Bowery, Broadway E W125-126) and 128 non-chain blockfaces. Not for this PR.
- Memory: no memory-pressure kill on my runs (peak about 214 MB test host, `autoreleasepool` around each blockface).

## What's working
- The original 3 trap blocks are fixed in both directions from every piece, including the 16-piece Cabrini block.
- The coordinate/fraction/segment placed directly with no re-snap removes the dead-band class of bug; "moved" is truthful in 978 flow walks.
- No stray onto another street or side, ever, with the whole tile set known (the 226 stray bug stays fixed).
- Riverside Dr, Central Park West, St Nicholas and Fort Washington Aves, which curve, walk consistently.
- Full suite 3393/0, merges cleanly with main and with #228.
