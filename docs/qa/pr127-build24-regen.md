# Build-24 Tile Regen QA — PR #127 (`data/build24-regen`)

**Reviewed:** branch `data/build24-regen` at `bea07c8f` (base `main` `ad07a293`), against the regen output itself — this is a regen-output verification, not a code review (the producing code — #116 geometry, #117 arrow-direction, #120 determinism, #126 width-offset — already passed QA on main).
**Verdict: 🟡 FIX — re-verify the lost-coverage list against one more live pull before Kevin's iOS archive step. Do not treat this as a clean MERGE-and-forget; do not hard BLOCK the branch either.**

## Summary

The code is sound: determinism is real (two scratch regens from an identical cached sign pull are byte-identical except `generatedAt`), the iOS `Resources/tiles/` mirror matches `tiles/` exactly, both of Kevin's field repros (E 4th St, Chrystie St) are correct in the actual shipped bytes, the three regression harnesses (`test-pipeline-determinism.js`, `test-arrow-direction-fix.js` 26/26, `test-width-offset-resurrection.js` 41/41) all independently reproduce, and the legality palette is clean (11 known categories, zero empty-rule/missing-category segments). Net blast radius is overwhelmingly positive: 1,007 blockfaces gained a new dominant category, 380 recovered from zero coverage, only 34 lost all coverage. **But that last number is where I found a real problem**: HANDOFF.md / open-items.md #33 characterize all 34 lost blockfaces as "self-referential degenerate blocks... plus a few re-anchored... not a regression." I independently geo-verified 20 of the 34 and found that characterization does not hold — only ~2-3 are cleanly self-referential/degenerate, a couple are pure cross-street-spelling renames with coverage intact nearby, but **roughly 12-14 are real, named NYC streets whose curb rules vanished with no replacement anywhere nearby** (e.g. Morningside Avenue, W123rd→Manhattan Ave, lost 26 real ASP/No-Standing/No-Parking segments spanning a quarter mile of Harlem curb). Re-running the identical PR code against a fresh live pull 2 days later recovered 5 of 12 checked (confirming pure day-of-pull Socrata timing noise for those), but 7 of 12 stayed missing even 2 days later — I can't distinguish "persistent pipeline gap" from "DOT genuinely retired those signs between the stale Sept-23 baseline and Oct-7" without ground-truthing live signage, which is out of scope here. This is why the verdict is FIX, not MERGE: the specific artifact being shipped needs one more live-pull sanity pass against this list before it reaches users, and the "not a regression" doc claim needs correcting regardless of what that pass finds.

## Priority-check results (from the dispatch brief)

1. **Determinism reproduced against committed output** — ✅ with one caveat (see below).
2. **iOS mirror integrity** — ✅ clean.
3. **Field cases in the actual committed bytes** — ✅ both confirmed, byte-level.
4. **Blast-radius sanity** — ✅ numbers reproduce exactly; 🔴/🟡 the lost-coverage spot-check (4a) is the real finding.
5. **Legality-palette corruption** — ✅ clean.
6. **Houston honesty** — 🟡 not independently re-derived in isolation (see below), but directionally consistent and not a blocker per the brief.
7. **Docs/HANDOFF accuracy, no Swift/Supabase** — ✅ confirmed no Swift/Supabase changes; 🔴 the lost-coverage characterization in the docs is the one factual error found.

## 1. Determinism reproduction

Checked out `bea07c8f` into a scratch dir, ran `node build/preprocess.js` twice with `SIGNS_CACHE_PATH` pointed at the same cached live sign pull (first run fetches live + caches, second run reuses the cache):

```
diff -rq scratch_out1 scratch_out2
Files scratch_out1/index.json and scratch_out2/index.json differ   (generatedAt only)
```

All 1,077 tile files byte-identical between the two runs. **Determinism gate holds**, independently reproduced, not just re-read from the PR's own log.

Caveat: diffing MY fresh-live-pull run (`scratch_out1`, pulled today, 2 days after the PR's own Oct-7 regen) against the PR's **committed** `tiles/` shows 40/1077 tile files differ, 46,822 vs 46,832 segments, 81 lost/71 gained segment IDs — but `compare-tilesets.js` between the two shows **zero rule-content drift and zero geometry movement on every segment that exists in both** (19,078→46,751 of them byte-identical, mean/max displacement both 0.00m). The only difference is which segments exist at all, concentrated in ~5 specific blocks (W42nd/9th-8th, Park Ave/E53-E52, W36th/7th-Broadway, 7th Ave/W51-W50, W104th). That's ordinary live-Socrata day-to-day churn (this repo's own open-items #10 already documents this phenomenon for a different metric), not non-determinism in the code — the code's own A/B against *identical* input is perfectly clean. Does not change the MERGE-worthiness of the code; it's relevant context for finding #1 below, where two of those exact same 5 blocks reappear.

## 2. iOS mirror integrity

```
diff -rq tiles/ ios/WePark/WePark/Resources/tiles/
(no output — exit 0)
```

Byte-identical. Clean.

## 3. Field-case byte verification

**E 4th St N (Bowery→2nd Ave):** the 8-segment blockface resolves `N_0`=NO_STANDING, `N_1`/`N_2`/`N_3`=**ASP_MON_THU** (exactly 3 dedicated dominant segments as claimed), `N_4`=NO_PARKING, `N_5`=NO_STANDING, `N_6`=METERED, `N_7`=NO_STANDING. `N_1`'s rule payload is literally `"NO PARKING (SANITATION BROOM SYMBOL) MONDAY THURSDAY 9AM-10:30AM <-> (SUPERSEDES SP-413C)"`, `arrow: "both"` — this is Kevin's exact SP-413CA sign. Confirmed in the real shipped bytes.

**Chrystie St E (Delancey→Houston):** diffed the pre-regen (main) vs post-regen (PR) tiles directly. Pre-regen had two segments with a genuine mixed/bled rule array (`_5`: dominant NO_STANDING but rules `["ASP_OVERNIGHT_MWF","NO_STANDING","ASP_OVERNIGHT_MWF"]`; `_9` similarly inverted) — exactly the "stray rule swap" HANDOFF describes. Post-regen, all 14 sub-segments resolve cleanly to one pure dominant category each, alternating NO_STANDING/ASP_OVERNIGHT_MWF pockets with no mixing. Cross-checked against the W (opposite) side of the same block, which carries ASP_OVERNIGHT_TTHS — the classic NYC complementary-day ASP pattern (MWF one side, TuThSat the other), which is an internally-consistent, plausible real-world signature. Confirmed in the real shipped bytes.

## 4. Blast-radius sanity

Reproduced every headline number independently via `scripts/compare-tilesets.js` (main's pre-regen committed tiles vs the PR's committed tiles) and a custom blockface-coverage script:

- 44,127 → 46,832 segments, 1,071 → 1,077 tiles — **matches exactly**.
- 1,349 lost / 4,054 gained segment IDs, 17,894 rule-content-drifted, 19,078 byte-identical, 5,806 geometry-moved (mean 15.19m) — **matches exactly**.
- 380 gained-from-zero blockfaces, 1,007 gained-new-category, **34 lost-coverage blockfaces — matches exactly**.
- Max geometry outlier: 6,555.03m, Harlem River Drive (FDR Dr→Dyckman St) [N] — matches the documented, pre-existing #32 degenerate pairing. Confirmed not new.

**Gained-from-zero spot check:** sampled 20 of the 380 (EAST HOUSTON STREET/2ND AVE-BOWERY, FORSYTH ST/Stanton-Houston, EAST 5TH ST, HUDSON ST, 6TH AVE, BOND ST, COOPER SQUARE, etc.) — all plausible real Lower-Manhattan blocks, no garbage.

**Absurd-mover hunt:** beyond the known Harlem River Dr #32 case, found several outliers >400m (Pearl St/John-Platt/Fletcher ~1,500m — this is the exact #120-documented John St/Pearl St cross-borough-disambiguation fix working correctly, ground-truthed via Nominatim to the real Financial District location, not Dumbo; ACP Blvd/W147-Macombs ~478m — the already-tracked #32-family degenerate pairing; Laurel Hill Terrace ~440-494m and East Houston St/1st-2nd Ave ~407m — both independently reverse-geocoded via Nominatim and both land ON the correct real street at the AFTER coordinates, while the BEFORE (main) coordinates sit ~450m off the real intersection. Net: every large mover I checked is a correction, not a new defect.

**🔴/🟡 Lost-coverage spot check — the actual finding.** The dispatch brief asked me to confirm the 34 lost blockfaces are "degenerate self-referential blocks (acceptable)" and BLOCK if a real block lost legit rules. I geo-verified 20 of the 34 (not just string-matched the `from==street` pattern) by finding the nearest same-street, same-side segment in the after-tileset and measuring the distance:

| Category | Count (of 20 sampled) | Examples |
|---|---|---|
| Clean self-referential/degenerate (replacement exists <2m away under a real name) | 2 | `6TH AVENUE\|6TH AVENUE\|BROOME ST` (0.9m), `MAIDEN LANE\|MAIDEN LANE\|WILLIAM ST` (1.3m) |
| Pure naming-variant rename (same exact curb, 2-14m away, under a different cross-street spelling — "SAINT NICHOLAS" vs "ST NICHOLAS", "FRED" vs "FREDERICK" DOUGLASS BLVD) | 2 | Both `WEST 116TH STREET` cases |
| Self-referential highway family (FDR Drive self-paired, consistent with the #32 pattern despite a large raw distance) | 1 | `FDR DRIVE\|FDR DRIVE\|E 62ND ST` |
| **Real, named street — nearest same-side replacement is 24m-2,500m away on a *different* block, i.e. genuinely zero coverage at that curb** | **12** | Morningside Ave (W123rd→Manhattan Ave, **26 real segments** of ASP_TUE_FRI/NO_STANDING/NO_PARKING, gone — nearest same-side match is 46-842m away), Washington Sq South, 7th Ave South, Avenue C, W36th St (7th Ave→Broadway S, 5 METERED segments near Macy's/Herald Sq), 7th Ave (W51st→W50th E, 2 METERED segments), E 44th St, W104th St, Manhattan Ave, W142nd St, W143rd St, St Nicholas Ave (×2 blocks), Fulton St |
| Ambiguous (traffic circle, "side" is loosely defined) | 1 | Columbus Circle E — likely a legitimate re-split, not scored as a real loss |

That's roughly **60-70% of the sample being genuine, non-degenerate real-street losses** — directly contradicting the "self-referential... not a regression" characterization in HANDOFF.md/open-items.md row #33.

**I then re-ran the identical PR code against a completely independent fresh live pull (2 days later)** and checked whether these specific real losses recover:

- **Recovered** (confirms pure live-data-pull-day timing noise, not a code defect): Morningside Ave/W123rd (27 segments back, even more than main's 26), W143rd St/ACP-Fred Douglass (8/8), St Nicholas Ave/W164-W163 (2/2), W104th St/Amsterdam-Columbus (7/7), Manhattan Ave/Morningside-Cathedral (11 vs main's 9, recovered).
- **Still missing 2 days later** (cannot rule out a persistent pipeline gap vs. a legitimate real-world sign removal between the stale Sept-23 baseline and Oct-7 — I cannot ground-truth live DOT signage from this sandbox): Washington Square South/Thompson-LaGuardia, Avenue C/FDR-E23rd, E 44th St/Madison-Vanderbilt, W142nd St/Edgecombe-Bradhurst, St Nicholas Ave/W162-Amsterdam, 7th Ave South/Barrow-Bleecker, Fulton St/Pearl-Water.

**Why this matters:** these are real curbs (Herald Square meters, Carnegie Hall-area meters, a quarter-mile of Harlem ASP/No-Parking/No-Standing on Morningside Ave) where the shipped build would show *no rules* where real rules exist — the exact failure mode a parking-ticket-avoidance app exists to prevent. The net regen is still a huge win (1,387 blockfaces gained coverage/category vs. ~24-30 that lost it), but the documentation's blanket "not a regression" claim is not accurate, and roughly half of the real losses do not self-heal on a quick re-pull.

## 5. Legality-palette integrity

All 46,832 segments use one of the 11 known `CATEGORIES` enum values (`ASP_DAILY`, `ASP_MON_THU`, `ASP_OVERNIGHT_MWF`, `ASP_OVERNIGHT_TTHS`, `ASP_TUE_FRI`, `METERED`, `NO_PARKING`, `NO_STANDING`, `SPECIAL`, `TRUCK_LOADING`, `UNKNOWN`). Zero segments with an empty `rules` array or missing `dominantCategory`. Clean.

## 6. Houston honesty

Not independently re-derivable in isolation from a main-vs-full-regen diff, because Allen/Bowery/Delancey/Houston are also among the streets whose block *geometry* moved under Option A's per-carriageway matching (confirmed from the preprocess.js log: `Matched streets:` includes ALLEN STREET, BOWERY, DELANCEY STREET, EAST/WEST HOUSTON STREET) — so a raw displacement measurement mixes re-anchoring with the width-offset itself and can't cleanly isolate the ~2.8m claim. As a sanity cross-check: Forsyth St (the stated unchanged control) measures 0.00m median displacement on matched-rule segments, and Bowery measures 2.49m median — both match the manifest's own numbers exactly. Re-ran `test-width-offset-resurrection.js` independently: 41/41 pass, including the Houston +6.79/+6.49m *pre-correction* number this test still checks against `street_widths.json` directly (that number is the raw per-street offset calculation, not the *net* delta vs. the pre-existing 10m floor — #126's QA already reconciled that distinction). Not a blocker per the brief; directionally consistent, not independently re-derived to the decimal.

## 7. Docs / HANDOFF / no Swift-Supabase

`git diff origin/main...origin/data/build24-regen -- . ':!tiles/*' ':!ios/WePark/WePark/Resources/tiles/*'` → only `HANDOFF.md` and `docs/open-items.md` changed. **Confirmed: zero Swift files, zero Supabase/SQL files touched** — this PR really is tiles + the iOS mirror + docs, as claimed.

`docs/open-items.md` row #33 (new) and rows #25/#26/#27 (amended to shipped-pending-build) — content is accurate **except** for the lost-coverage characterization covered in finding #1 below. The regen numbers, field-case claims, and determinism-gate description in both HANDOFF.md and open-items.md are otherwise accurate and independently reproduced.

One structural note, not a blocker: `data/build24-regen` branches from `ad07a293` (pre-`#121`/`#122`), not from current `main` tip `f9f3c7d4`. Confirmed zero file overlap with `#121`/`#122`'s changes (curb-snap/plant-model are iOS-only, this PR is tiles+docs-only), so a normal merge commit will not conflict or silently drop anything — just flagging since the repo's own memory notes call out exactly this class of stale-base risk for review.

## Findings

### 🔴 Blocking (recommend resolving before Kevin's iOS archive step, not necessarily before merging the branch)

- **#1: The "34 lost-coverage blockfaces are self-referential degenerate blocks, not a regression" claim in `HANDOFF.md`/`docs/open-items.md` #33 is not accurate — most are real NYC streets with real rules that went dark**
  - Where: `docs/open-items.md` row #33, `HANDOFF.md`'s 2026-10-07 changelog entry; manifest produced by `scripts/compare-tilesets.js` + the shipped `tiles/`.
  - What: of 20 of the 34 lost blockfaces geo-verified (nearest same-street-same-side segment in the after-tileset), only ~3 are genuinely self-referential/degenerate or clean renames; ~12 are ordinary named streets whose curb rules (METERED, ASP_*, NO_STANDING, NO_PARKING) vanished with the nearest same-side replacement 24m-2,500m away on a *different* block — i.e., real gaps, not relabeling. Worst case: Morningside Avenue (W123rd St→Manhattan Ave, W side) lost all 26 real rule segments covering a quarter mile of Harlem curb.
  - Expected: per the project's own severity bar for data regens, a real block going dark should either not happen or be explicitly caught and called out, not folded into a "not a regression" blanket statement.
  - Repro: run `node build/preprocess.js` from `bea07c8f` against the committed `osm_data.json`/`osm_oneway.json`/`street_widths.json` with a live `SIGNS_CACHE_PATH`-cached sign pull; diff the 34 IDs in open-items.md #33's own methodology against the committed pre-regen (`main`) tiles using a geographic nearest-neighbor check (not a string match) — the full list and per-block distances are in section 4 above.
  - Owner: `@backend-data`
  - **Mitigating evidence, same finding:** re-running the identical code against a fresh live pull 2 days later recovered 5 of 12 real losses checked (Morningside Ave, W143rd St, St Nicholas Ave/W164, W104th St, Manhattan Ave all came back with full or near-full segment counts) — confirming those specific ones are live-Socrata day-of-pull timing noise, self-healing on any subsequent regen, not a code defect. The other 7 (Washington Sq South, Avenue C, E44th St, W142nd St, St Nicholas Ave/W162, 7th Ave South, Fulton St) stayed missing even 2 days later — I cannot distinguish "persistent pipeline gap" from "DOT genuinely retired those specific signs between the stale Sept-23 baseline and Oct-7" without ground-truthing live signage, which is outside this sandbox's reach.
  - **Recommendation:** (a) correct the "not a regression" language in both docs to reflect the true breakdown; (b) before Kevin's iOS archive/TestFlight step consumes these tiles, run one more live regen and re-check this specific list of blocks — if the 7 persistent ones are still missing, that's worth a dedicated root-cause session (is the live Socrata data genuinely gone, or is something in the geometry/arrow/determinism pipeline dropping them?) before calling this closed; (c) this does not need to block the branch merge itself (the code is sound, 0 rule-drift / 0 geometry-drift on everything that matches, and the net regen is a big win) — it needs to block the "ship to users" step, which per HANDOFF is Kevin's separate iOS build/archive anyway.

### 🟡 Significant

- **#2: `compare-tilesets.js`'s "RULE-DRIFT PROOF: FAIL" exit code fires on this comparison and will fire on every future non-isolated-input regen diff** — not a bug, just a usability note: the script's exit-1/"do not merge" messaging is calibrated for its original purpose (same-input A/B isolating one axis of change) and reads alarmingly when used for a genuine content regen (which is explicitly this PR's point). Low cost to add a `--expect-drift` flag or separate "manifest mode" vs "gate mode" to avoid a future engineer misreading the exit code as a real failure. `@backend-data`.

### 🟢 Minor / nit

- **#3:** `data/build24-regen` branches from `ad07a293`, one commit behind current `main` tip (`f9f3c7d4`, includes #121/#122 iOS-only changes). No file overlap, so this doesn't block the merge, but worth a habit check for the next tiles PR given this repo's own memory note about stale-base risk on concurrent branches.

### 💡 Out of scope (logged, not fixed)

- Houston's width-offset delta could not be cleanly isolated from the Option A geometry re-anchoring in a main-vs-full-regen diff; the existing isolated unit test (`test-width-offset-resurrection.js`) already covers this axis and passed 41/41 independently re-run here. A dedicated isolated-input A/B (same technique #116's own QA used) would be the rigorous way to re-confirm the net Houston delta if anyone wants decimal-level certainty later.

## Smoke tests run

- Checked out `bea07c8f` to a scratch dir (did not touch the shared worktree's branch).
- Ran `node build/preprocess.js` twice with `SIGNS_CACHE_PATH` pinned to the same cached live pull → byte-identical tile output except `generatedAt`. **Determinism gate independently reproduced.**
- `diff -rq tiles/ ios/WePark/WePark/Resources/tiles/` on the PR's own commit → empty, confirmed identical.
- Ran `scripts/compare-tilesets.js` (a) between my two same-input scratch runs (zero diff but timestamp), (b) between my fresh live pull and the PR's committed tiles (40/1077 tiles differ, zero rule-drift, zero geometry-drift on matching segments — explained as live-data timing noise), (c) between pre-regen `main` tiles and the PR's committed tiles (reproduced every headline manifest number exactly: 44,127→46,832 segments, 17,894 rule-drifted, 19,078 identical, 5,806 geometry-moved mean 15.19m, max 6,555.03m Harlem River Dr).
- Independently re-ran all three of the PR's own regression harnesses from the scratch checkout: `test-pipeline-determinism.js` (PASS, 3 pinned + 64 ambiguous-pool brute-force-verified + 204×10 fuzz shuffle, all byte-identical), `test-arrow-direction-fix.js` (26/26 PASS), `test-width-offset-resurrection.js` (41/41 PASS).
- Pulled the exact field-case segments (E 4th St N, Chrystie St E) out of the real committed `tiles/` JSON and read the rule payloads directly — not relying on the PR's own described outcome.
- Diffed pre-regen `main` tiles vs the PR's committed tiles for the Chrystie St blockface specifically, to confirm the "stray rule swap" bug described in HANDOFF actually existed pre-regen and is actually gone post-regen (not just asserted).
- Reverse-geocoded 2 of the largest geometry movers (East Houston St/1st-2nd Ave, Laurel Hill Terrace) via Nominatim to confirm the AFTER coordinates land on the real street/address and the BEFORE coordinates do not — both confirmed as corrections, not new defects.
- Built a custom blockface-coverage diff script (street|from|to|side keyed) and independently reproduced the 34/380/1,007 manifest numbers exactly.
- Built a geographic nearest-neighbor recheck script (haversine distance to nearest same-street-same-side segment) to classify 20 of the 34 lost blockfaces as degenerate/renamed/genuinely-lost — this is the basis of Finding #1.
- Re-ran the same geo-check against a fresh independent live pull (same PR code, 2 days later) to separate "live-data timing noise, self-heals" from "stayed missing" for 12 of the real losses.
- Grep/scripted check of all 46,832 segments' `dominantCategory`/`rules` for palette corruption — clean.
- `git diff --name-only` with `tiles/`/iOS-mirror excluded to confirm the non-tile diff is exactly `HANDOFF.md` + `docs/open-items.md`, no Swift/SQL.

## What's working

- The determinism fix is real and reproducible from scratch, not just re-reported from the PR's own log — this was the single highest-stakes claim in the whole regen and it holds up.
- Both of Kevin's hand-verified field repros (E 4th St, Chrystie St) are correct in the actual bytes being shipped, verified by reading the real tile JSON and, for Chrystie St, by diffing against the actual pre-regen bug to confirm the described defect really existed and really got fixed.
- iOS mirror sync is exact — no drift between what was "verified" and what the app bundle actually ships, which has been a real historical failure mode in this repo (per HANDOFF's own note about PRs #21/#22).
- The width-offset and arrow-direction regression suites both independently re-run clean, and the geometry-movement sanity check found every large outlier I dug into (Pearl St/John St cross-borough fix, Laurel Hill Terrace, East Houston St) to be a genuine correction toward the real-world location, not a new defect — Nominatim-verified, not just asserted.
- Zero Swift/Supabase touched, exactly as claimed — this really is a scoped, tiles-only regen.
- The net blast radius is a real, large net win for users: 1,007 blockfaces gained a new rule category they were missing, 380 went from zero coverage to real coverage. The lost-coverage finding doesn't erase that — it just means the "zero regression" framing needs correcting and one more pull-and-check pass before this specific artifact reaches TestFlight.
