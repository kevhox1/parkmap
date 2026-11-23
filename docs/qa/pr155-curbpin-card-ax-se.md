# PR #155 QA Pass 1: curb-pin card at AX sizes and SE (#37 item 8), 2026-11-23

**Reviewed:** branch `fix/curbpin-card-ax-se` at `a6deb319`, against `docs/design/curb-pin-placement-design.md` ("Addendum - placement card at accessibility sizes and SE") and the findings in `docs/qa/curbpin-flip-smoke-2026-11-23.md`.
**Rig:** iPhone 17 sim (402x874) and a temporary iPhone SE 3rd gen sim (375x667), iOS 26.5, one `xcodebuild build` of the branch with `curbPinPlacementEnabled` and `driveModeDefaultEnabled` flipped to true LOCALLY (discarded, never committed). No `xcodebuild test` run (CI ran the suite). Every screenshot was read.
**Verdict:** MERGE-WITH-FOLLOWUPS. The hard requirement held in every state and at every size I could reach, on both phones. No blocking finding. The follow-ups are small and the feature is dark behind `curbPinPlacementEnabled=false`. Coverage gaps (listed below) are because the disk guard (5 GB) tripped during the SE phase; they are stated, not silently passed.

## Summary
The ScrollView design is gone and the card is a fixed-height stack whose size comes from a pure selector. I could not break "title + status fully visible, primary visible, no scroll" on the 17 at Large, XXXL, AX1, AX3, AX5 (snapped, far-curb at Large/XXXL/AX1, no-curb, no-data, Report-pill entry, long two-line street name, long status string) or on the SE at Large, XXXL, AX1, AX3, AX5 (snapped). AX2..AX5 render identically to AX1 (clamp applied on the overlay in ContentView works). The AX5 self-overlap is gone, Locate sits top-right at AX1+, the ASP banner hides per the rule and returns on Cancel. Findings #1, #2, #3, #4, #6 from the flip smoke are fixed.

## Acceptance criteria checklist
- [x] No ScrollView / ViewThatFits in the card; explicit `.frame(height:)` from `CurbPlacementCardLayout` (code read).
- [x] Hard requirement (title + status never scroll, primary visible): live, see matrix.
- [x] Tip frozen at entry (0.40 / 0.36 / 0.30) and threaded through session, controller, reticle, pin query (diff read; live tip y matched the fraction on both phones).
- [x] 130 pt gap never shrunk: measured gap 143 to 198 pt at every cell reached.
- [x] Clamp `.dynamicTypeSize(...accessibility1)` on the overlay in ContentView (diff read; live AX3 and AX5 identical to AX1).
- [x] ASP banner hidden only on <700 pt phones or AX1+; restored on exit; no `mapZStack` growth (the `if` sits inside the existing top `safeAreaInset`).
- [x] Locate top-right at AX1+; clear of the car pin (17 AX1/AX5 screenshots).
- [x] Hint pill off the pin head on SE Large (pill bottom 156, pin head top 177).
- [x] VoiceOver label = visible street + side ("8 Avenue, East side" for the visible "8 Ave . East side"); value starts "between ..." and carries status and the far-curb footnote.
- [x] Title case: "8 Ave", "W 122 St", "Fred Douglass Blvd", "Frederick Douglass Blvd".
- [x] Flag-off guards intact by code: `curbPlacement?.hidesASPBanner != true` is true whenever the session is nil, so the banner path is unchanged; defaults 0.40 keep every legacy caller identical. Live flag-off screenshot NOT taken (disk guard), recommend the existing flag-off CI guards plus one launch before the flip.
- [ ] SE far-curb, SE no-curb / no-data / Report path at AX, far-curb at AX3/AX5, loading on cold launch at AX: not reached (see Coverage gaps). Not failures.

## Measured matrix (my numbers, points)
Card top = title frame y minus 16 (matches the screenshot edge). Tip from the screenshot needle tip.

| Phone / size / state | Tip y | Card top | Gap | Title + status | Primary | Notes |
|---|---|---|---|---|---|---|
| 17 Large snapped (long-press) | 350 | 548 | 198 | full, status 640-... | Park here y 712 | link row shown, banner shown (874 tall, not AX) |
| 17 XXXL no-curb | 352 | 499 | 147 | full | y 684 | link shown, banner shown, Cancel y 162 |
| 17 XXXL far-curb | ~352 | 499 | ~147 | title 515-583, chip full | y 684 | footnote in subtitle slot |
| 17 AX1 no-curb | 316 | 488 | 172 | full (title 504, chip 594-682) | Save car here (2 lines) y 732 | no link, banner hidden, Cancel y 70, Locate top-right |
| 17 AX1 snapped, 2-line title + 2-line chip | 316 | 488 | 172 | full ("Fred Douglass Blvd . East side" wraps, "Free until Today 8:30 AM" wraps) | y 732 | cross street one line, uppercase |
| 17 AX3 no-curb | 316 | 488 | 172 | full | y 732 | identical to AX1 |
| 17 AX5 no-curb | 316 | 488 | 172 | full | y 732 | identical to AX1, no self-overlap |
| 17 AX5 Report pill entry (snapped, "Frederick Douglass Blvd . West side", "Restricted") | 316 | 488 | 172 | full, 2-line title | Next | banner hidden; Cancel restored pitched ambient and banner |
| 17 AX5 no-data (Cupertino) | 316 | 488 | 172 | title full, instruction line visible | Save car here (2 lines) | status slot empty by design |
| 17 Large snapped, long cross street + long status ("between FRED DOUGLASS BLVD & ADAM C POWELL BLVD", "Free until Tomorrow 8:30 AM") | 350 | 548 | 198 | full, cross street scaled to fit one line | y 712 | |
| 17 Large far-curb (live) | 350 | 548 | 198 | "Fred Douglass Blvd . East side", chip, "(i) Nearest curb with data" | Park here | |
| SE Large snapped | 240 | 383 | 143 | full (chip 463-507, not clipped) | Park here y 547 | link shown (compact), banner hidden, hint pill shown clear of pin head |
| SE XXXL snapped | 240 | 386 | 146 | full | y 571 | link dropped, banner hidden |
| SE AX1 / AX3 / AX5 snapped | 200 | 349 | 149 | full (title 365, chip 482-) | y 559, h 92 | link + subtitle dropped, Locate top-right, identical across the three |

Card bottom equals the screen bottom at every cell (no overflow, no self-overlap). Gap is at or above 130 everywhere.

## Status of flip-smoke findings
| # | Smoke finding | Status |
|---|---|---|
| 1 | AX1+ legality hidden, AX5 self-overlap | FIXED. 17 AX1/AX3/AX5 and SE AX1/AX3/AX5 verified live. |
| 2 | SE chip clipped at Large, hidden at XXXL/AX1 | FIXED. SE Large, XXXL, AX1 verified. |
| 3 | Hint pill over pin head (SE) | FIXED on SE Large (pill bottom 156 vs head 177). Suppression at SE AX could not be re-seen (hint is once-only per install; pure test covers it). |
| 4 | 128/129 pt gap | FIXED. 143-198 measured. |
| 5 | Report pin not on the puck | Out of this PR's scope; unchanged. |
| 6 | Uppercase title, VoiceOver label mismatch | FIXED for title and label. Cross-street subtitle still uppercase (see deviations). |

## Findings

### Blocking
None.

### Significant
None.

### Minor
- **#1: Mid-session Dynamic Type growth on the SE can overflow the primary by about 5 pt.** Where: `CurbPlacementCardLayout.resolve(tipFraction:...)` at a frozen tip. What: entry at Large on SE freezes tip 0.36 (cap 297). If the user then raises text to AX (Control Center), the view resolves at 0.36 and the last candidate at that tip (no link, no subtitle, content 318) exceeds the 297 cap, so `cardHeight = min(content, cap)` = 297 and the 92 pt primary extends about 5 pt below the card background. Title and status (end at +194) stay fully visible, so the hard requirement still holds. Derived from the code, NOT reproduced live (disk guard). Expected: acceptable by the PR's own deviation 6; log as a known edge. Owner: `@ios-engineer`, no action needed pre-merge.
- **#2: Cross-street subtitle stays upper-case while the title is title-cased** ("Fred Douglass Blvd . East side" above "between ST NICHOLAS AVE & W 122 ST"). Deviation 4. Visual inconsistency only. Owner: `@ios-engineer` / `@designer`.
- **#3: Long cross street shrinks to the 0.7 scale floor** ("between FRED DOUGLASS BLVD & ADAM C POWELL BLVD" renders about 16 pt tall at Large). Still one legible line, nothing hidden. Acceptable; note for the designer.

### Out of scope (logged, not fixed)
- `expandedStreetName` maps "ST NICHOLAS AVE" to "Street Nicholas Avenue" in the VoiceOver label/value (pre-existing, the `ST` token is always read as Street; should be "Saint"). Owner `@ios-engineer`.
- At AX5 the ambient (non-placement) layer has the Search button overlapping the ASP banner; pre-existing, not this PR.

## Rulings on the builder's deviations
1. **Acronym list (FDR, BQE, LIE, JFK, MLK stay upper-case):** ACCEPT. Matches the orchestrator's "FDR Dr" ask and is better than "Fdr Dr". Risk is limited to a real street literally named one of those words.
2. **Cross-street line still uppercase:** ACCEPT as a follow-up (finding #2). Not a legality or layout issue.
3. **No-curb instruction dropped on SE at AX:** ACCEPT as designed (spec trade-off); title says "No curb here", the nearest-curb chip is in the status slot, the VoiceOver value carries the instruction. Not verified live on the SE (see gaps); the 17 AX no-curb card shows the instruction and fits.
4. Link roomy/compact variants and fixed-height chip (deviations 1 and 2): ACCEPT; the long status string rendered two-line wrap at AX and one line at Large with nothing hidden.
5. Entry plan reads the key window once and the frozen tip never moves (deviation 6): ACCEPT with minor finding #1 noted.

## Smoke tests run
- Built once (simulator, flags flipped locally) and installed on the 17. Cold launch: full overlay layer renders (search, More, ASP banner, Start Driving, goal dock). Read screenshot.
- 17: long-press entry at Large, XXXL, AX1, AX3, AX5; no-curb, snapped, far-curb (Large live, XXXL and AX1 attempted: XXXL far-curb live, AX1 landed snapped), Report-pill entry at AX5 via More then Report, no-data in Cupertino at AX5, long street names and status strings in Harlem (Frederick Douglass Blvd, W 122 St). Cancel at AX5 restored the pitched ambient camera and the ASP banner. `axe describe-ui` frames and VoiceOver label/value read at each stop.
- SE (created, used, deleted): cold launch, snapped at Large, XXXL, AX1, AX3, AX5 with frames and screenshots; hint pill at Large.
- Code read of the selector, resolve, metrics, `hidesASPBanner`, `hintPillCenterY`, the ContentView entry plan and clamp, the controller/reticle tip threading and the flag-off banner guard.

## Coverage gaps (not verified)
Disk fell to 4.7 GB during the SE phase (guard is 5 GB), so I stopped live work and cleaned up. NOT verified live:
- SE: far-curb, no-curb, no-data, Report-pill path at any size; SE AX no-curb in particular.
- Far-curb at AX3/AX5 (the far-curb slot is the same fixed subtitle slot; my AX attempts landed snapped).
- Loading state on cold launch at AX.
- Flag-off live screenshot (needs a second build); mid-session Dynamic Type change; #147 frame-by-frame no-jump (tip y matched the configured fraction and Cancel restored the ambient camera, but I only sampled 3 s after entry).
- VoiceOver traversal on a device, SE hardware: Kevin's list.
Recommend one SE live pass over no-curb / no-data / Report at AX1 and XXXL before the flip.

## What's working
- The requirement holds with margin: slack never below 13 pt and the structure (top-aligned fixed slots, no scroll) makes legality the last thing a shortfall could touch.
- Clamp-on-overlay genuinely collapses AX2..AX5 to AX1 on both phones.
- Locate at top-right at AX1+ and banner hiding remove the car-pin collision and the AX5 overlap.
- Report-pill and long-press paths behave the same; the Report card shows the same title/status.
- Far-curb footnote replacing the subtitle looks clean and keeps the card height constant.

## Rig cleanup
Local flag edits discarded, derived data (`~/Library/Caches/wepark-qa155-dd`) removed, SE simulator deleted, all simulators shut down, 17 content size reset to `large`.
