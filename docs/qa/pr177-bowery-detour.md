# PR #177 QA — Bowery hairpin-detour fix (open item #35) — 2026-11-24

**Reviewed:** branch `fix/bowery-sign-data` at `68885ad5`, against open-items #35 and the PR description
**Verdict:** MERGE-WITH-FOLLOWUPS (iOS CI was still `pending` when this report was written. Merge is conditional on it going green.)

## Summary
The guard is narrow and sound. I A/B'd old vs new `getBlockPolyline()` on the same `osm_data.json` for all 10,936 block-sides in the committed tiles. Exactly 23 block-sides change, and every one is a hairpin detour. No non-detour block moves. The Bowery Bleecker->E Houston (W) block now sits south of Bleecker at 323 ft instead of covering Bond / Great Jones / E 2nd, and E 2nd->E 3rd (E) moved to its correct latitude. The four pipeline test scripts pass. The one caveat is that the owner's Overnight-goal green line may not be fully gone, for a reason unrelated to this PR (see F1).

## Acceptance checklist
- [x] Guard logic reviewed. It is gated by `!isSelfReferential`. It only fires when `len > 2*straight + 30m`, so non-detour blocks never enter the branch. It re-ranks all candidate pairs by chain length with the 2 m plausibility floor kept, and adopts only if the new length is under 75% of the old. Otherwise it falls through to the original pair (counted in `DETOUR_STATS.unresolved`).
- [x] No collateral. The old-code vs new-code A/B over every committed block-side (script run on the worktree) gives `blocks 10936, err 0, changed 23`. All 23 are E Houston x10, Riverside x5, Bowery x4, Varick x2, Canal, 8th Ave and W116. Old lengths were 378–12,792 ft (a pre-trim figure, measured on the raw extracted line). New straight-line distance is about 130–1,800 ft.
- [x] `node scripts/test-bowery-detour.js` PASS. `test-pipeline-determinism.js` PASS (65/65 brute-force pairs, 205 blocks x 10 shuffles byte-identical). `test-arrow-direction-fix.js` 26/0. `test-width-offset-resurrection.js` 41/0.
- [x] `tiles/` and `ios/.../Resources/tiles/` are identical (`diff -rq` is empty).
- [x] Bowery data on the branch vs main (committed JSON):
  - Bleecker->E Houston W: main covered lat 40.72534–40.72638 (wrong, over Bond/Great Jones/E 2nd). Branch covers 40.72431–40.72518, 323 ft, south of Bleecker. The rule is the same `3 HMP COMMERCIAL VEHICLES ONLY` meter.
  - E 2nd->E 3rd E: main covered 40.72644–40.72701 (that is the E 3rd->E 4th range). Branch covers 40.72568–40.72622, 207 ft, east curb. This is a second wrong-block bug fixed by the same change.
  - Great Jones->Bond W (218 ft), Bond->Bleecker W (84 ft), E 4th->Great Jones W, E Houston->E 1st E, E 1st->E 2nd E and E 3rd->E 4th E are byte-identical to main.
  - Nothing from the Bleecker->Houston block remains north of lat 40.7252, so none of its rules sit over the Bowery Hotel curb.
- [x] Other fixed blocks, geometry only. All move to lengths close to the straight-line distance: Riverside 97th–104th 2300->1800 ft (E) and 2179->1790 ft (W); Riverside W94–95 E 248->182 ft; E Houston Ave B–A N 688->544 ft; E Houston Elizabeth–Bowery S 253->174 ft; Varick Vandam–Spring E/W 218->203 ft and 253->230 ft. No two-point or empty results.
- [x] Of 10,937 old block-side groups, 10,726 are fully byte-identical in the tiles. 113 have changed geometry, 92 have rule-only changes, 6 are lost and 5 gained. I verified the guard A/B only (geometry on identical OSM). The remaining tile movement, such as E 73rd and Thomas St, comes from the Oct->Nov data pull, and the 20 non-detour blocks in that list are outside the guard's reach. I could not re-run the same-pull rule A/B offline, so I am taking the PR's "0 rule changes" claim on trust. Nothing contradicts it.
- [x] Prior field-repro streets are present with identical segment counts to main: Morningside Ave 75, Morningside Dr 72, Chrystie St 66, East 4th St 103.
- [x] Lost 6: 2nd Ave E43->E42 W, 3rd Ave E42->E43 W, Van Corlear Pl, and 3 x Fred Douglass Blvd. The 3 Fred Douglass blocks all reappear as "Frederick Douglass Blvd" (renames, gained list). Gained 5: those 3 plus W58 Grand Army Plaza->5th N and 5th Ave E116->E115 E. This is plausible churn, not a regression.
- [ ] iOS CI "Build and XCTest (Xcode 26)": still `pending` at report time. Must be green before merge.

## Findings

### Blocking
None.

### Significant
- **F1: The owner's green line may persist on Great Jones->Bond W (and E 4th->Great Jones W) under the Overnight goal, for an unrelated reason.**
  - Where: tiles, `BOWERY_GREAT_JONES_STREET_BOND_STREET_W_1`, `BOWERY_EAST_4TH_STREET_GREAT_JONES_STREET_W_1`.
  - What: after this fix the Bowery Hotel curb segments carry NO_PARKING 8a–6p (segments 0 and 2) and a regular `2 HMP 7:30AM-7PM EXCEPT SUNDAY` METERED rule plus ASP_DAILY (segment 1, about 100 ft). Per the PR, Free Overnight treats METERED as free. So at 1 pm Tuesday the middle segment of Great Jones->Bond W may still render green, even though the commercial-meter mis-paint is gone.
  - Expected: the owner should know this is the rules-engine behaviour on the block's own legitimate rule, not a residual detour bug.
  - Repro: not verified live (no simulator run). Recommend a live look after the next build.
  - Owner: `@ios-engineer` / rules-engine decision.
  - This is not a defect in PR #177's pipeline change.

### Minor / nit
- **F2:** The PR text says "23 detoured, 20 fixed, 3 unresolved". My A/B shows 23 block-sides whose geometry changed. I did not enumerate the 3 unresolved ones, which would be 3 more block-sides still detoured (or this counts something differently). Cosmetic mismatch. The builder should confirm which 3 remain and that they are tracked (open-items row #35 lists them).
- **F3:** The guard re-ranks over all pairs, so it costs more CPU on the 23 detoured blocks. It is not an issue at runtime.
- **F4:** `DETOUR_STATS` is accumulated but never printed. Add a console log in the build summary so a future regen shows the count.

### Out of scope (logged)
- Commercial-vehicles-only meters are categorized METERED (open follow-up already in #35).

## Smoke tests run
- Created a worktree of the PR branch under `~/Library/Caches/qa177` and ran all 4 test scripts: PASS.
- Wrote a temporary old-vs-new `getBlockPolyline()` A/B over all 10,936 tile block-sides (old code loaded from `origin/main`): 23 changed, 0 errors.
- Tile-level diff of main vs branch (loaded JSON): 10,726 groups byte-identical, with 6 lost and 5 gained as above.
- Per-segment dump of the Bowery west curb rules and coordinates on the branch.
- `df -h /` checked: 7.4 GB free. No Xcode or simulator used, since no mount-chain files changed. The branch touches `preprocess.js`, tiles, tests and docs only. Worktree removed after.
- Not verified: iOS CI result (pending) and any live-app rendering.

## What's working
The guard's gating means nothing outside the 23 detour blocks can change, and I confirmed that with the A/B. It also fixed E 2nd->E 3rd (E), a second wrong-block mapping that wasn't mentioned in the report. The regression test pins both the geometry and the control block.
