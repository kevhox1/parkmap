# PR #158 live QA: address-anchored parking MVP + street-name ordinals

**Reviewed:** `feat/address-anchored-parking-mvp` (CI green), built locally and run on the iOS 26.5 simulator (iPhone 17, plus an iPhone SE 3rd gen for AX3 checks). Local flags only (reverted): `driveModeDefaultEnabled`, `curbPinPlacementEnabled`, and for flag-on runs `addressAnchoredParkingEnabled`. Two builds (flag off, flag on). Build only, no `xcodebuild test`.
**Verdict:** MERGE-WITH-FOLLOWUPS. Flag-on works end to end in the happy path (address appears after settle, "Park here" carries it to the parked-car sheet, survives relaunch) and the ordinal change renders correctly. There are no blockers: the address feature is dark, and the only ungated change is the formatter. One ungated cosmetic regression (mixed case "E 2nd ST") and one flag-on layout trade-off should be fixed before the flag flips.

## Per-check table

| # | Check | Result | Evidence |
|---|---|---|---|
| 1a | Flag-off card identical to main layout | PASS (visual) | Large/XXXL/AX1/AX3 flag-off: legality, cross-street, Park here all present, no extra row (`assets/pr158/E1st_large_off.png`, `ax1_off.png`, `ax3_off.png`). Byte-identity not proven (no main build run); layout matches PR #156/#157 QA descriptions. |
| 1b | Flag-on card at Large | PASS | Title, legality chip, "between ...", "In front of 94 E 1st St", Park here, Report all visible, no clipping (`E1st_large_on.png`). Card is ~24 pt taller than flag-off (reserved row). |
| 1c | Flag-on XXXL | PASS | All rows incl. address and Report visible (`xxxl_on.png`). |
| 1d | Flag-on AX1 / AX3 (iPhone 17) | PASS with finding 2 | Legality + Park here always visible, no clipping; cross-street AND address rows dropped (`ax1_on.png`, `ax3_on.png`). Flag-off keeps the cross-street at the same sizes. |
| 1e | SE, AX3, flag-on | PASS | Title, wrapped legality chip, Park here fit, nothing clipped (`se_ax3_card_on.png`). SE Large/XXXL flag-off vs on NOT run. |
| 1f | Card height constant during drag | PASS (observed) | Dock top identical between settled/no-curb/on-curb frames at Large and AX; no height jump seen. Could not capture a finger-down frame (AXe limitation). |
| 2 | AX3 goal card "Overnight" | PASS | One line, large and fully legible on iPhone 17 and on SE (`goal_ax3_iphone17.png`, `goal_ax3_se.png`). No visible shrink on either; no stacked-layout change needed. |
| 3a | Tier "In front of" mid-block | PASS | E 1st St North side (between E Houston & 1st Ave): "In front of 94 E 1st St" (stable across Large/XXXL/relaunch); Ave A East side: "In front of 14 Ave A"; W 11th St North side: "In front of 155 / 145 W 11th St". |
| 3b | "Near ..." tier | NOT OBSERVED | Never triggered in ~8 settles. Device/more-blocks check. |
| 3c | Blocks with no address | OBSERVED | E 2nd St South side (Ave A to 1st Ave) and Ave A West side: no line after 5+ s and repeated nudges; silent. Could be geocoder returning avenue/corner/other-side results (the intended block-only path) or the 30 s back-off; cannot tell without logs (addresses are deliberately not logged). See finding 4. |
| 3d | Parity on both sides of one street | PARTIAL | Only north/east sides verified (E 1st N even, Ave A E even, W 11th N odd). Opposite side of the same street not reached (E 2nd S returned nothing; AXe drags onto the W 11th south curb did not take). Tile-side vs geometry on W 11th: see finding 5. |
| 3e | Nothing during drag; line cleared on move | PASS with finding 3 | On no-curb and on a new block the line is gone after ~3 s. One frame right after release still showed the old address under "No curb here" (`stale_line_nocurb.png`). |
| 3f | Park here: address on parked-car sheet | PASS | Headline "In front of 14 Ave A" above the rules (`parked_sheet_address.png`). |
| 3g | Survives relaunch | PASS | Terminated and relaunched; reopened car sheet via pin: AX label "Parking in front of 14 Avenue A". |
| 4 | Offline | DEVICE-ONLY | Did not disable the Mac network. Code-read: coordinator is silent on `.unavailable`, retries once on foreground. |
| 5a | Ordinals ungated (flag OFF) | PASS | Flag-off build: title "E 1st St", "between E Houston St & 1st Ave" (`E1st_large_off.png`). |
| 5b | Ordinals elsewhere | PASS with finding 1 | Card title, between line, parked-car sheet, block detail all ordinalised; AX labels "East 1st Street", "between East 2nd Street and East Houston Street". "6th Ave & 7th Ave S", "W 11th St" correct. |
| 5c | 11th/12th/13th, FDR Dr, report rows | PARTIAL | W 11th St verified. 12th/13th, "FDR Dr", report/confirm rows NOT reached. |
| 6 | #157 regression: no post-release camera move, Cancel, Park here | PASS | Multiple drags settled with no camera drift; Cancel exits cleanly to goal selector; Park here saved at the snapped curb. Chip tap partially nudged and left "No curb" (not touched by this diff, see finding 6). |
| VO | Spoken form | PARTIAL | AX tree shows "Parking in front of 94 East 1st Street. between East Houston Street and 1st Avenue. Free until..." Audio and the queued announcement not heard (device-only). |

## Findings

### Blocking
None.

### Significant
- **#1: Mixed-case "E 2nd ST" / "1st ST" in uppercase surfaces (UNGATED)**
  - Where: parked-car sheet subtitle ("AVE A — East side · between E HOUSTON ST and E 2nd ST"), block detail ("between AVE A and E 1st ST"). `assets/pr158/parked_sheet_address.png`, `block_detail_caps.png`.
  - What: those views show the raw all-caps street; the formatter now lowercases the ordinal suffix only, leaving "ST"/"HOUSTON" upper. Before this PR the same strings read consistently "E 2ND ST".
  - Expected: consistent casing (apply formatter before the uppercase transform, or title-case the whole string).
  - Repro: park anywhere, open the car sheet or tap a block on an ordinal street. Ships even with the flag off.
  - Owner: `@ios-engineer`
- **#2: Flag-on drops the cross-street line at AX1/AX3 where flag-off shows it**
  - Where: placement card, iPhone 17 and SE, `accessibility-medium` / `accessibility-extra-large`.
  - What: flag-off AX1/AX3 shows title, legality, "between E Houston St & 1st Ave", Park here. Flag-on shows title, legality, Park here only. The reserved address row pushes the cross-street out. Legality and primary are safe; this is an information loss that appears only when the flag flips.
  - Expected: per the design addendum rows drop by priority, so this is defensible, but "cross street beats address" would be the better priority (an address that drops with the cross street is fine; the reverse loses today's information). Needs the designer pass the PR already calls for.
  - Owner: `@ios-engineer` + designer

### Minor / nit
- **#3: One stale-address frame on moving to no-curb** (`stale_line_nocurb.png`): frame captured right after a 0.2 s swipe showed "No curb here" with the previous "In front of 94 E 1st St" still under it. Gone by 3 s. Code calls `placementSnapChanged(nil)` in the same handler, so likely a one-frame observation lag. Spec says never show stale. Low.
- **#4: Address coverage in the simulator**: 3 of ~6 blocks resolved. Sim uses Apple's live geocoder; a device may differ. Worth a device pass on avenue-facing and corner blocks before the flag flips (spec's "avenue number under the street" case is the intended block-only outcome, and could not be told apart from a failure here).
- **#5: W 11th St (Greenwich Ave / 7th Ave S area)**: the highlighted curb sits on the visually south edge of the carriageway while the card says "North side"; the probe steps toward the labeled side. Not conclusive (odd triangular intersection, rotated basemap) and tile labeling is not part of this diff. Recommend a device or data spot check of the side label there.
- **#6: Chip "Nearest curb N ft" partially nudges** (three tries left "No curb here"); unchanged by this diff (no chip/camera lines in the ContentView diff). Pre-existing, out of scope.

### Out of scope (logged)
- Supabase "no address in request body" protocol test deferred by the builder: the diff has no `ParkedCar`/`ParkingAddress` references in Supabase services, so nothing sends it today. A cheap structural test would still be good insurance.
- Privacy policy and App Store privacy answers (stream F), designer pass (stream E).

## Device-only / not covered
- Offline behavior and reconnect + foreground fill-in.
- VoiceOver audio and queued announcement.
- "Near ..." tier, both sides of one street, corner building facing an avenue, FDR Dr, W 12th/13th St, report/confirm/spot rows, lock-screen notification text.
- SE Large/XXXL/AX1 flag-off vs on pairs.

## What's working
- Settle-debounced address appears reliably on resolvable blocks, never mid-drag, and the reserved row means no card jump when it fills in.
- Park here carries the address to the sheet headline and it persists across relaunch.
- Ordinals read right on the card title and "between" line with the flag fully off.
- AX3 goal card "Overnight" is clean on both phones.
- Legality and primary action are never clipped at any tested size.

## Cleanup
Constants.swift reverted, Config.xcconfig removed, sims shut down, SE device deleted, app uninstalled, derived data deleted. Screenshots in `docs/qa/assets/pr158/`.

## Follow-up spot-check (2026-11-24)

**Reviewed:** PR #158 head `c6fbe87d` (the "one street-name display entry point" commit `a35bdca3` plus the test-expectation commit), built locally, iPhone 17 sim, iOS 26.5, East Village. Local flags only (reverted). Two builds: `addressAnchoredParkingEnabled` OFF, then ON. Build only, no `xcodebuild test`.
**Verdict: MERGE.** Both significant findings are fixed. No new findings.

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Finding #1, ungated casing (flag OFF) | PASS | Parked-car sheet subtitle now "1st Ave — East side · between E 1st St and E 2nd St" (was "AVE A ... E HOUSTON ST and E 2nd ST"): `assets/pr158/off_parked_sheet.png`. Block detail "E 2nd St — North side", "between Ave A and 1st Ave": `off_block_detail.png`. Placement card "1st Ave · East side", "between E 1st St & E 2nd St": `off_card_large.png`. No mixed-case "ST" anywhere I reached. |
| 1b | Surfaces not reached live | UNIT ONLY | FDR Dr, confirm/report/spot-placement rows, reminder title not reached in the sim (the report sheet opened from block detail shows no street name). Covered by the new unit tests in the PR (not run locally); spot-placement and reminder-title expectations were updated in the second commit. Not verified live. |
| 2a | Finding #2, flag ON, AX1 (`accessibility-medium`) | PASS | Card shows title, legality, "between E 1st St & E 2nd St", Park here. Cross-street line stays, address row dropped: `on_ax1_card.png`. |
| 2b | Flag ON, AX3 (`accessibility-extra-large`) | PASS | Same as AX1 (`on_ax3_card.png`); legality and Park here always visible, nothing clipped. |
| 2c | Flag OFF AX1 unchanged | PASS | Title, legality, "between E Houston St & E 1st St", Park here (`off_ax1_card.png`); same row set as the earlier report's flag-off AX1. |
| 2d | Card height steady during drag | NOT VERIFIED | My AXe swipe on the map did not move the camera/pin, so there was no drag to observe. Card top edge identical in settled frames at 1 s and 7 s at AX3. Earlier-pass observation of constant height still stands; this diff only changes row-drop priority. |
| 3a | Address line at default size, flag ON | PASS | "In front of 14 1st Ave" under the cross-street line after settle (`on_large_card.png`). |
| 3b | Park here to parked-car sheet | PASS | Sheet headline "In front of 14 1st Ave" above "1st Ave — East side · between E 1st St and E 2nd St" (`on_parked_sheet.png`). |
| 3c | Camera drift after release (#157) | PARTIAL | No drift seen across settled frames; the drag itself was not exercised (see 2d). Diff does not touch camera code. |

### Findings
None new. Observation only: live-switching content size did not re-flow the card title (same size at AX1/AX3); layout otherwise matches the earlier pass.

### Cleanup
Constants.swift reverted, Config.xcconfig removed, app uninstalled, sim shut down, derived data deleted. Screenshots: `docs/qa/assets/pr158/{off,on}_*.png` (downscaled).
