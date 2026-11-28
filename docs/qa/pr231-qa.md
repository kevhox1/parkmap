# PR #231 (R35-2 content-sized search card sheet) QA - 2026-11-28

**Reviewed:** `ios/r35-2-sheet-height` at `db91235d`, against `docs/specs/r35-map-polish-and-trip-destination.md` (PR4) and field log R35-2.
**Verdict:** PASS with follow-ups (no blocking findings).

## Summary
The Penn Station card now opens at its content height: no dead gap, "Drive here" sits right under the goal chips, and the sheet resizes when the count line changes. AX5 opens `.large` only and scrolls with Drive here pinned. The suite is green on a clean erased sim. Follow-ups are cosmetic spacing, plus the other-sheet audit the builder skipped.

## Acceptance criteria
- [x] Penn Station card has no gap - live, `docs/qa/pr231-assets/penn-9-free.png` ("9 free curbs" state) and `penn-no-free.png` (the exact build-35 "No free curbs ... 760 ft away" state from Kevin's screenshot). The map shows noticeably more than in build 35.
- [x] Chip change / count change resizes smoothly, no clipping - tapped "For days": count card went from "9 free curbs" to "No free curbs" and the sheet got about 20 pt shorter, still flush.
- [x] AX5 (accessibility-extra-extra-extra-large) - `penn-ax5.png`: `.large` only, header stacks, Close and Drive here large, chips scroll under the pinned Drive here. Switching back to default size re-detented to the content height.
- [x] Typing state stays `.medium`/`.large` - `typing.png`; Close from the card returns to that state at medium.
- [x] No detent loop / jitter observed - sheet settled at one height across count change, size change and re-open. Code: `wpReportHeight` ignores changes under 2 pt and rounds to 1 pt; the measured content is the ScrollView's inner VStack, so the sheet height cannot feed back into the measurement. Not recorded as video, so very fast flicker on a device is not excluded.
- [x] Dismissal - Close goes to the peek/typing sheet; Cancel goes to the rest state. Both fine.
- [x] Park flow files untouched - diff is `ContentView.swift` (2 presentation lines), new `WPSheetSizing.swift`, `WPSearchV2.swift`, tests.
- [x] Drag to `.large` available (`[.height(h), .large]`); map interaction enabled up to the content detent. Code read; map interaction beside the card was not tapped live.
- [x] Long content scrolls - AX5 shows the ScrollView scrolling; at default size the content is under 85% of the screen so the clamp only matters for AX/landscape.

## Findings
### Blocking
None.

### Significant
None.

### Minor
- **#1: spacing is looser than the spec's 8-12 pt.** Chips to "Drive here" is about 25 pt (body bottom padding s3 + footer top padding s2), and there is about 45-50 pt of empty card below the button on iOS 26. It reads fine and is a big improvement, but it is not the tight 8-12 pt in the spec. Owner `@ios-engineer`, polish.
- **#2: first-frame height not observed.** Until both the body and footer are measured, `measuredCardHeight` is 0 and `clamp` returns the 260 pt minimum, then the sheet grows. My 1 s screenshot after tapping a result already showed the final size, so I did not catch a visible resize, but a short grow on open is possible on a slow device. Watch for it. Owner `@ios-engineer`.
- **#3: iOS 26 vs earlier branch.** `if #available(iOS 26)` skips the bottom inset; earlier iOS adds it. Only iOS 26.5 was exercised. Recheck on an older sim if the deployment floor matters.

### Follow-ups (logged, not fixed)
- **Other sheets, as asked.** More sheet (`more-sheet.png`): content ends and there is about 225 pt (roughly 670 px at 3x) of empty sheet below Settings at the default `.medium`, more than the builder's 80 pt estimate. Candidate for the same helper. Curb sheet and My Car sub-sheets (reminders, signs, leaving): NOT audited live. They need a parked car and a tapped curb, which I did not set up. Treat as unknown. Other sheets are unaffected by this PR (the detent modifiers are applied inside `WPSearchSheetV2` only, and the only `ContentView` change removes the search sheet's own two lines).

## Smoke tests run
- Full `WeParkTests`, shipped flags, freshly created/erased `wepark-qa231-sim`, `-parallel-testing-enabled NO -jobs 4`: 3,440 tests, 0 failures, 1 skipped.
- Dry-run merges (real `git merge --no-commit`, aborted, nothing pushed): clean vs latest `origin/main` (includes #228/#229), clean vs #233, clean vs #232 (`ios/f1-trip-destination`). The combined result was not compiled.
- Live flag-on build (`StoopFlag` and `driveModeDefaultEnabled` flipped locally, reverted, never committed): Penn Station search at default size (two count states) and AX5, typing state, dismissal, More sheet. Screenshots inspected, saved in `docs/qa/pr231-assets/`. Mount-chain check: toolbar (search, More, Locate), banner, dock and curb polylines rendered.

## What's working
- Kevin's exact Penn Station case is fixed, including the "No free curbs" variant.
- Sensible design: pure `WPSheetSizing` with tests (clamp, NaN, hysteresis), ScrollView kept so long content and AX5 still scroll, and the iOS 26 bottom-inset deviation is documented in a comment and was correct (no 34 pt gap).

## Kevin on device
1. Search "Penn Station" and pick it, in the "No free curbs" state and with free curbs: the card should be flush with Drive here and not leave a gap. Tap different goal chips and watch the sheet resize without bouncing.
2. Watch the first half second after picking a result for a sheet that opens small and then grows.
3. Drag the card up to full height and back; pan the map beside the card.
4. Larger Text at the maximum: everything should scroll, with Drive here pinned.
5. Open More: the large empty area at the bottom is the known follow-up.
