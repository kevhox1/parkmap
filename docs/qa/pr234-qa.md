# PR #234 QA (DT35-3 nudge uses a block spine)

Reviewed: branch `ios/dt35-3-nudge-direction` at `bd34b4f8`, against `docs/qa/pr229-qa.md` findings #1, #2, #3, #6. QA agent did not build this. Own sim `wepark-qa234-sim` (iOS 26.5), own derived data, both deleted at the end. Logic only, Stoop on, behind the dark VoiceOver flags. Not a mount-chain PR (no `MapViewRepresentable`, `ContentView`, `DriveMode*`), so no live-UI smoke; the live VoiceOver path on a device is not verified.

**Verdict: PASS with follow-ups.** Every #229 finding is fixed on real tiles. In 84,036 walks from every piece, at the start, middle and end, both ways, over 3,359 blockfaces, I saw 0 strays, 0 steps under 0.5 m, 0 walks without an end, and 0 inconsistent ends within a connected run. The full suite is green. I found one real curb left off the spine (Cooper Square, 6.2 m, one in 10,315 runs) and a class of short parallel stubs that get bridged and walked backwards for the last few metres. Neither breaks the walk. Both are follow-ups.

## Acceptance criteria

- [x] Paladino Ave E and W: one direction for the whole block, both ends reached, 94 to 104 steps max from every piece/fraction/direction. See "Named cases".
- [x] Bowery W Canal-Bayard and Broadway E W125-126: "End of block" reached, one end each way, 23 and 11 steps max.
- [x] The 3 original #226 blocks (West End Ave E W66-70, 2nd Ave W E61-62, Cabrini Blvd E W187-190): one end each way from every piece.
- [x] Ends no longer depend on the start piece: 0 forward-spread and 0 back-spread (over 3 m) in 3,363 runs. The spine itself is identical whichever piece it is built around: 0 differences in 3,363 runs (all pieces) and 10,315 runs (first vs last piece).
- [x] Stays on the blockface: 0 strays (same street/side/both cross streets), 0 crossings into another connected run.
- [x] Every step at least 0.5 m: 0 short steps in 84,036 walks.
- [x] Ends within a bounded number of steps: max 320 steps (5 m steps), 0 walks hit the cap.
- [x] Within each connected run, forward ends at the same place and back at the other end: 0 `FWDSPREAD`, 0 `BACKSPREAD`, 0 `SAMEEND`. (Ends differ by under 0.5 m at most, because a final step under 0.5 m returns End of block.)
- [x] Out-and-back drift: max 4.5 m (LaGuardia Pl W, 3 steps out/3 back at 5 m, one step clamped at the block end). Bounded by one step, not a spine fault.
- [x] Cache is invalidated correctly (see "Cache").
- [x] Perf: the pieces are cached; a spine build takes at most 9.0 ms (59 pieces, Riverside Dr W W155-135), 1 in 10,315 above 5 ms; a full `nudge` takes 7 to 19 ms on the 5 biggest blocks (35 to 59 pieces) on a loaded Mac. The longest-path search is capped at 50,000 expansions.
- [x] Full `WeParkTests`, shipped flags, freshly created and erased sim: 3,451 run, 1 skipped, 0 failures. Peak test-host memory 686 MB (sampled every 5 s), no kill.
- [x] Dry-run merge, `git merge-tree --write-tree`: clean against latest `origin/main` (`922267e3`, has #231 and #233) and against `origin/ios/f1-trip-destination` (#232; it touches `ContentView`, `TripPlanning`, `WPPlaceResolver` and trip views only, no overlap with `WPParkFlowV2.swift` or `WPBlockSpine.swift`).
- [ ] "Never hide a real curb": one real, uncovered 6.2 m NO_PARKING piece is left off the spine (finding #1).

## What I ran

Own test, real tiles, all 47,696 segments, blockface = (street, side, from, to) as `isSameBlock`. My own connected-run definition (piece ends within 6 m), my own walker calling the public `nudgeTarget(on:fraction:meters:in:)` so the spine is rebuilt around every landing piece, as the app does. Files: `docs/qa/pr234-assets/QA234Tests.swift.txt` and `QA234bTests.swift.txt` (not in the target); outputs next to them.

- **Sample:** every 5th multi-piece blockface starting at index 2 (2,060), plus every multi-piece blockface on: Lexington Ave (202), Park Ave (209), Park Ave South (29), 2nd Ave (213), Madison Ave (204), West End Ave (87), East Houston St (27), West Houston St (22), Canal St (40), Delancey St (38), Riverside Dr (104), Riverside Blvd (11), and every street containing "BROADWAY" (Broadway 380, West Broadway 35, East Broadway 15, Old Broadway 4, Broadway Terrace 2). Total 3,359 blockfaces, 3,363 multi-piece runs. Not the builder's every-7th.
- **Walks:** from every piece at fraction 0, 0.5, 1.0, both ways, 5 m steps, cap max(400, 3x run length / 5): 84,036 walks. Checks above, plus "ends within 5 m of the run's farthest-apart ends".
- **Out-and-back:** from mid-piece of every piece over 12 m, 1/3/6 steps out and back, both signs.
- **Spine audit over all 10,315 multi-piece runs** (not just the sample): determinism, dropped pieces, bridges, end shortfall, build time.
- **Stub flow** through `nudge`: every dropped piece, 3 fractions, both ways, through the controller; compared `flow.model` against `WPNeighborVerdict.resolve` for the landed piece.
- **Cache** scenarios through the controller.

| Check | Result |
|---|---|
| Walks | 84,036; stray 0; crossRun 0; shortStep 0; noEnd 0; fwdSpread 0; backSpread 0; sameEnd 0 |
| Spine differs by start piece | 0 of 3,363 (all pieces) and 0 of 10,315 (first vs last) |
| Max steps | 320 |
| Max out-and-back drift | 4.499 m (one 5 m step clamped at the end) |
| Runs with other than 2 loose ends | 24 in the sample (53 in all data), all walked clean |
| Blocks with a real gap (more than one run) | 20 in the sample, each run walked on its own, 0 crossings |
| Full suite | 3,451 run, 1 skipped, 0 failures |

My own check "walk ends within 5 m of the farthest-apart ends" flagged 63 walks in 3 blocks (Paladino E back, Riverside Dr E W160-161 forward, West Broadway W Franklin-Leonard forward). I looked at each, none is a walk fault. Paladino E: the 9.3 m first piece hooks back (its end is farther from the far end than its start), so the block's end is the piece start, 9 m from my "extreme". The other two are finding #2.

## Named cases

Spine dumps and walks, from `named-cache-output.txt`.

| Block | Pieces | Spine | Result |
|---|---|---|---|
| Paladino Ave E (E 120th-1st Ave) | 13 | 13 legs, all forward, 520 m | 1 end each way, max 104 steps |
| Paladino Ave W | 14 | 14 legs, all forward, 469 m | 1 end each way, max 94 steps |
| Bowery W Canal-Bayard | 6 | W_0 to W_4 and W_5 reversed after a 5.5 m bridge | 1 end each way, 23 steps (see #2) |
| Broadway E W125-126 | 3 | E_0, E_1; E_2 (3.9 m) off the spine | 2 ends, 11 steps; stub's rules same category (ASP_TUE_FRI) as the covering piece |
| West End Ave E W66-70 | 11 | 11 legs | 57 steps, one end each way |
| 2nd Ave W E61-62 | 3 | 3 legs (one-ended chain) | 12 steps, one end each way |
| 2nd Ave W E59-60 (60-59 side) | 7 | run A: W_5 (2.1 m) alone; run B: W_21 to W_26, all six on the spine (2, 3, 2, 2, 2, 15 m) | the real 2 m consecutive pieces are kept; the 17 m gap between W_5 and W_21 is walked per run, not bridged |
| 2nd Ave W E59-58 | 3 | 3 legs (23, 30, 5 m) | the 5 m end piece is kept |
| Cabrini Blvd E W187-190 | 8 | 8 legs | 41 steps, one end each way |

## Cache

Through the controller (`testCache`), results in `named-cache-output.txt`:

- Draft ends (`reset()`), new draft on another block: nudge stays on the new block. OK.
- Switch from block A to block B without a reset, and back: stays on the right block. OK.
- Side flip (`switchSide`) then nudge, flip back and nudge: each stays on its own side; the opposite-curb search stays on the same street. OK.
- Tile reload with a different segment set (count changes; block A cut to 2 pieces): the walk only visits those 2 pieces, so the cache is dropped when the set changes. OK.
- Tile reload with the same count, first id and last id but different content: the new content is ignored, the walk still lands on the old geometry (finding #3). Not reachable with the static bundled tiles.

The block key is `street|from|to|side` (all four fields), the street key is the street name, and both are dropped by `knownSegments.didSet`. The cache is not cleared when the draft ends, only when the segment set changes. It holds at most one street list per street plus the blocks used, so memory is small and it can only be stale if the data changes.

## Findings

### Significant (follow-up)

- **#1: One real curb is left off the spine and is not alongside any other piece (Cooper Square E E5-E6, piece E_3).**
  - Where: `WPBlockSpine.buildLegs` step 3/4 (longest simple path leaves out a branch).
  - What: `COOPER_SQUARE_EAST_5TH_STREET_EAST_6TH_STREET_E_3` is 6.2 m of NO_PARKING. It branches off the middle of the block, 2 to 6 m from the metered piece E_2 and from the NO_STANDING pieces E_0/E_1; none of its 3 sample points is within 4 m of any spine piece. It is the only one of 10,315 runs where a dropped piece has a different dominant category from the pieces around it. The other 3 dropped pieces (Edgecombe Ave E E_35 2.9 m, Broadway E W125-126 E_2 3.9 m, and `..._AVENUE_S_0`) have the same dominant category as the spine piece next to them, so dropping them is harmless.
  - Effect: a car placed on it (drag) and then nudged is moved onto the spine, and gets the verdict of the metered or no-standing curb. The nudge never lands on it. Your rule is to never hide a real curb; this one is hidden from the nudge.
  - Expected: a piece that is not alongside another is either on the spine or not a place the walk silently relocates from; at minimum a test that fails when a dropped piece is not covered.
  - Repro: `WPBlockSpine(around:in:)` on the Cooper Square block, `legs` has E_0 E_1 E_2 only. Flow: enter pending on E_3, `nudge`.
  - Owner: `@ios-engineer`

### Minor / nit

- **#2: Short parallel stubs 2.5 to 6 m off the main line are bridged and walked backwards at the end.** `isCovered` needs 3 points within 2.5 m; a stub 3 to 5 m off the line is not covered, so the spine bridges to its far end and walks it reversed.
  - 5 of 10,315 runs end with a bridged tail under 15 m: Bowery W Canal-Bayard (W_5, 5.5 m bridge, 4.9 m tail), Riverside Dr E W160-161 (E_2, 3.5 m bridge, 5.3 m tail), West Broadway W Franklin-Leonard (W_4, 4.8 m bridge, 2.6 m tail), E 112th St N 2nd-1st Ave (1.5 m bridge, 12.8 m tail), E 42nd St S 1st Ave-FDR (1.5 m bridge, 14.5 m tail).
  - Effect: the last "forward" step jumps the bridge, then travels back along the stub. VoiceOver says "moved" and the car does move at least 0.5 m, then "End of block", always at the same point, up to 6.6 to 6.8 m short of the true end (Riverside Dr, West Broadway). No ping-pong. Same-category verdicts in the three I checked.
  - Owner: `@ios-engineer`
- **#3: Segment-set version is count + first id + last id; a same-version set with different content is ignored.** `enterPending` used to take whatever set it was passed; it now only takes it when the version changes (`WPParkFlowV2.swift`, `enterPending`), and `prepareIndex` already did the same. Proved with a mutated set of identical count/first/last (the walk landed on the old 11.6 m geometry). The bundled tiles are static so I could not reach this in the app; a panned viewport that clips a block differently with the same count and ends would be the only way. Nit; a content-sensitive version would remove it.
- **#4: `pieces(...)` caches are not cleared on `reset()`.** They survive across drafts while the segment set is unchanged. Correct, small, but different from "cached while a draft is active". No action needed.

### Out of scope (logged)

- A one-piece run next to a real gap (2nd Ave W E60-59 W_5, 2.1 m) answers End of block while the block goes on 17 m away; that is the specified per-run behaviour for a real gap. Not a bug here, but a VoiceOver user is told "End of block" at a gap.
- The builder's own `WPParkNudgeTrapTests` was not reviewed beyond its header; my own tests above are what I rely on.
- Live VoiceOver on a device, and a live-UI smoke, not run (logic only).

## What's working

- The whole #229 list is gone: Paladino's direction flip, both stub ping-pongs, and all ~16 start-piece-dependent ends, over a different and larger sample than the builder's.
- The spine is the same whichever piece you build it around, in all 10,315 runs.
- The 2 m consecutive pieces on 2nd Ave W E59-60 are all kept, and the 17 m real gap is walked per run, never bridged.
- Stubs that are really alongside another piece (Broadway E W125-126, Edgecombe) are dropped with the same category, and a car started on one gets the verdict of the piece it lands on (0 mismatches in 24 stub flows).
- Nudges are 7 to 19 ms on the biggest blocks, against filtering all 47,696 segments before.
- Full suite 3,451, 0 failures, and clean merges with `main` and #232.
