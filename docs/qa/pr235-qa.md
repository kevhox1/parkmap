# PR #235 QA (DT35-3 spine keeps other-kind curbs, bridges only continuing gaps, content version)

Reviewed: branch `ios/dt35-3-spine-categories` at `bf8babb5`, against `docs/qa/pr234-qa.md` findings 1 to 4. QA agent did not build this. Own sim `wepark-qa235-sim` (iOS 26.5), own derived data, both deleted at the end (checked: 0 matches). Logic only, Stoop only, behind the dark VoiceOver flags. Not a mount-chain PR, so no live-UI smoke; the live VoiceOver path on a device is not verified. Raw data and my test sources are in `docs/qa/pr235-assets/` (not in the target).

**Verdict: PASS with follow-ups.** All four claimed fixes hold on real tiles. Across all 10,315 runs no folded piece differs in kind from its neighbour, the Cooper Square 6.2 m NO_PARKING piece is its own run, a car on any piece always shows its own piece's verdict, 60,702 walks are clean, and the full suite is green. The follow-ups are small: a car started on one of two short stubs ends 4.8 to 6.1 m short of the line end, the version hash ignores geometry, and the builder's weakened consistency check now hides exactly that stub gap.

## Acceptance criteria

- [x] Dropped piece differs in kind from its neighbour: 0 of 8 folded pieces (all 10,315 runs, 47,008 pieces).
- [x] Cooper Square E E5-E6 E_3 (6.2 m NO_PARKING) is its own run: `WPBlockSpine(around: E_3)` returns `[E_3]`, a car on it keeps its NO_PARKING verdict and never leaves it (9 own-run flows, 0 moved). It is the only own-run piece in the data (1 of 47,008).
- [x] Never a verdict for a curb the car isn't on: 91,053 flow checks (every piece of the sample, 3 fractions, nudged forward, back and not nudged), 0 cases where `flow.model` differs from `WPNeighborVerdict.resolve` of `flow.snap.segment`; 0 un-nudged cars off their own piece; 0 landings in another run.
- [x] Walk invariants: 60,702 walks, 0 strays, 0 crossings into another run, 0 steps under 0.5 m, 0 walks without an end (max 320 steps), 0 `FWDSPREAD`/`BACKSPREAD`/`SAMEEND`, 6 own-run walks never left their piece.
- [~] Stub runs from #234 finding 2: walks that start on the line now end at the true end within 0.2 m (Bowery, West Broadway, Riverside). Walks that start on the stub itself end 6.1 m (Bowery) and 4.8 m (West Broadway) short. See finding 1.
- [x] Bridging: no backward walk on the stubs. Bowery W_5, Riverside E_2, West Broadway W_4 and the other two #234 stub runs are not on the spine, so there is no bridged tail. E 112th St and E 42nd St all 8 and 4 to 7 pieces on the spine, ends within 0.4 m.
- [x] `contentVersion`: same-count, same-first-id, same-last-id set with a middle id swapped now differs; reordering two ids differs; same set twice equal; empty vs one differs.
- [~] Hash cost: 12.2 ms per call on 47,696 segments in a Debug build on a loaded Mac (load 100 to 200). Per tap/drag start/`.task`, not per nudge. See finding 3.
- [x] `reset()` clears the piece caches: 2 cached lists after a nudge, 0 after `reset()`.
- [x] Nothing stale across drafts, blocks, sides, reloads: B after reset stays on B; B then A without reset stays on A; side flip and flip back each stay on their own block; reduced set after reset only visits the 2 kept pieces; same count/first/last with a walked piece's id swapped: the walk sees the new id and not the old one.
- [x] Full `WeParkTests`, freshly erased sim: 3,496 total, 3,495 passed, 1 skipped, 0 failed (includes the builder's `WPBlockSpineKindTests`).
- [x] Merge: `git merge-tree --write-tree` clean against `origin/main` (`74685b75`, unchanged since the PR's base) and against #216 (`feat/stoop-web-p-preview`, web only, no overlap).

## What I ran

Own tests, real tiles (all 47,696 segments), blockface = (street, side, from, to), my own connected-run definition (piece ends within 6 m), my own "same kind" (dominant category plus set of rule categories, written separately from the PR's `sameKind`), my own nearest-piece check. Sample for walks and flows as asked: every 6th multi-piece blockface starting at index 4, plus all blockfaces on Cooper Square, Bowery, West Broadway, Riverside Drive, E 112th St, E 42nd St, any street containing BROADWAY and EDGECOMBE: 2,234 blockfaces, 2,239 runs. Rule audit and spine determinism: all 10,315 runs.

| Check | Result |
|---|---|
| Rule audit, all runs | 10,315 runs, 47,008 pieces: 46,999 on spine, 8 folded, 1 own-run. Folded with a different kind from the nearest spine piece: 0. Folded with another kind within 4 m: 0. Own-run piece that is really the same kind: 0. Spine around any spine piece differs from the main spine: 0. |
| Folded pieces | 10th Ave W16-W17 E_2, E_3 (special), Bowery W_5, Broadway E W125-126 E_2, Edgecombe E_35, Riverside E W160-161 E_2, W 163rd S_0, West Broadway W_4. All same category and same set of rule categories as the nearest spine piece. 6 of 8 have a rule list that is not byte-equal to the neighbour (description text etc.), same categories. |
| Walks | 60,702 (every piece, 0 / 0.5 / 1, both ways, 5 m): stray 0, crossRun 0, shortStep 0, noEnd 0, fwdSpread 0, backSpread 0, sameEnd 0, max 320 steps |
| Flow | 91,053 checks: modelMismatch 0, landedOtherRun 0, ownRunMovedOffItself 0; 56,217 nudges moved, 4,485 end of block or stayed |
| Stub runs, line starts | Bowery 0.2 m, West Broadway 0.0 m, Riverside 0.0 m from the line end |
| Stub runs, stub starts | Bowery 6.1 m, West Broadway 4.8 m, Riverside 0.2 m from the line end |
| Hash | 12.2 ms, 47,696 ids, Debug, loaded Mac |
| Full suite | 3,495 passed, 1 skipped, 0 failed |

## Findings

### Significant (follow-up)

None.

### Minor / nit

- **#1: A car started on a folded stub answers End of block 4.8 to 6.1 m short of the line end, and the builder's consistency check no longer notices.**
  - Where: `WPBlockSpine.position(of:)` (satellite placed at its nearest spine point) and `WPParkNudgeTrapTests.check` (`guard onSpine.contains(start.id) else { continue }`).
  - What: 30 walks start on a folded piece. 4 end more than 3 m from the ends the line walks reach: Bowery W_5 forward (6.1, 5.5, 5.5 m), West Broadway W_4 forward (4.8 m). Same-category verdicts. Before this PR's test change the old check (ends within 3 m whatever the start) would flag these; after it, a stub start does not vote on ends, so the only guard left on stub starts is the stray/step/bound checks.
  - Judgement on the test change: it is right to group by spine, because an own-run piece (Cooper E_3) legitimately ends within itself. Dropping stub votes is a small weakening: 26 of 30 stub walks agree with the line, the 4 that do not are on 2 stubs, and my independent test still shows them. A cheaper, stricter guard: let stubs vote with a looser limit (say 8 m), so a stub that wanders further than its own length still fails.
  - Expected: a car on a stub placed beside the line end and nudged forward should reach the line end, or at least be told End of block at the line end.
  - Repro: Bowery W Canal-Bayard, enter pending on `BOWERY_CANAL_STREET_BAYARD_STREET_W_5`, nudge forward.
  - Owner: `@ios-engineer`

- **#2: A real curb on its own run is not reachable by nudge, and a car on it cannot nudge off.** Cooper Square E E_3 (6.2 m): from the main line a nudge never lands on it, from it a nudge answers End of block within 6 m while the block goes on 7 m away. That is the specified behaviour (never relocate a different-kind curb), and the curb is reachable by drag or "Park here", so it is not hidden. A VoiceOver user is told End of block at a point where the block continues. Worth a copy line or a "nearby curb" cue later. No action for this PR.
  - Owner: `@ios-engineer` (follow-up)

- **#3: `contentVersion` is an id-only hash and costs one pass over every segment each time it is called.**
  - Where: `WPParkFlowController.contentVersion`, called from `prepareIndex` and `enterPending`.
  - What: (a) the hash covers count plus ids, so a set with the same ids and changed geometry or rules is the same version (my test: same id, line shortened: the old 21.6 m geometry is still walked). Bundled tiles are static and ids encode block and index, so this is theoretical. (b) 12.2 ms per call on 47,696 segments in Debug on a Mac at load 100 to 200 (in an earlier run, 603 of 943 profiler samples while I called `enterPending` 91k times with the full set were inside it). It runs once per tap, drag start or `.task`, never per nudge, so a single 12 ms in Debug is not a user-visible cost; a Release figure was not measured. It was O(1) before.
  - Expected: acceptable. If the set ever updates in place, hash a cheap geometry digest too, or cache the version beside the segment array.
  - Owner: `@ios-engineer`

- **#4: The builder's `cachedPieceListCount` is an internal read-only property added only for a test.** Documented as such, no production reader. Fine, noted so it is not used elsewhere.

### Out of scope (logged)

- Spine builds are the long pole in tests: my walk test (60,702 walks over 2,239 runs) took 26 minutes in Debug on a loaded Mac. That is test scale, not user scale: one build per nudge on a block (typically under 10 ms, per #234 QA).
- Live VoiceOver on a device and live-UI smoke not run (logic only).

## Cache

`reset()` empties both lists (count 2 to 0). Cache keys are unchanged (block key has all four fields, street key is the street). Segment-set change clears them via `knownSegments.didSet`; the new version check notices an id change with unchanged count and ends. `placeDraft` (used by `nudge`) skips the hash, so a nudge cannot reset the cache by itself. No stale-state case found.

## What's working

- The Cooper Square piece is kept, and it is the only one of 47,008 that needed it. The other 8 folded pieces are really same-kind stubs: nothing real is hidden.
- The bridge check works: the 5 backward-walking stub runs from #234 no longer have a bridged tail, and walks from the line end exactly at the line end (0.0 to 0.2 m).
- The verdict shown always belongs to the piece the car is on (91,053 checks).
- Spine is identical whichever spine piece it is built around (0 differences, all runs).
- Full suite 3,496 tests with the builder's new tests, clean merges with main and #216.
