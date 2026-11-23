# Curb-pin SE live pass (#37 8a), 2026-11-23

**Reviewed:** `main` at `2c7057a9` (includes PR #155, `19e75053`), built locally with `driveModeDefaultEnabled` and `curbPinPlacementEnabled` flipped to true (local edit, reverted, never committed). Against the "placement card at accessibility sizes and SE" addendum in `docs/design/curb-pin-placement-design.md`.
**Rig:** temporary iPhone SE 3rd gen sim (375x667, iOS 26.5), one `xcodebuild build` (no tests), AXe for long-press / taps / `describe-ui` frames. Every screenshot was read. Screenshots (375 px wide) are in `docs/qa/assets/se-curbpin-2026-11-23/`.
**Verdict:** PASS. No finding blocks the flip. The SE cells that the PR #155 pass could not reach (no-curb, no-data, Report-pill path, at XXXL and AX1) all hold the acceptance spec. Two cosmetic findings (green), one out-of-scope observation.

## Matrix (SE, flag-on, points)

Tip y is the needle tip (240 at XXXL, 200 at AX1, the frozen 0.36 / 0.30 fractions). Card bottom equals the screen bottom (667) in every cell.

| State / entry | Size | Title + status / message visible, no scroll | Primary (frame) | Report link | ASP banner | Locate | Notes |
|---|---|---|---|---|---|---|---|
| No-curb, long-press (MSG) | XXXL | "No curb here" y402, "Nearest curb 190 ft" chip y488, instruction y532 | "Save car here (no parking info)" y571 h80 | dropped | hidden | beside card (right, y326) | pass (`x-nocurb.png`) |
| No-curb, long-press | AX1 | "No curb here" y365, chip y482 | same label, y559 h92 | dropped | hidden | top-right | instruction line dropped (per spec); pass (`a-nocurb.png`) |
| No-curb, Report pill (More > Report) | XXXL | title y402, chip "Nearest curb 230 ft" y488, instruction y532 | "Next" y571 h80 | dropped | hidden | beside card | pin sits on the puck; pass (`x-report.png`) |
| No-curb, Report pill | AX1 | title y365, chip y482 | "Next" y559 h92 | dropped | hidden | top-right | pass (`a-report.png`) |
| No-data (Cupertino), long-press | XXXL | "No parking data here" y402, "You can still save your car at this spot" y530 | "Save car here (no parking info)" y571 h80 | dropped | hidden | beside card | pass (`x-nodata.png`) |
| No-data, long-press | AX1 | "No parking data here" y365 (one line, w328) | same, y559 h92 | dropped | hidden | top-right | instruction dropped, empty band; see #1 (`a-nodata.png`) |
| No-data, Report pill | XXXL | title y402, "You can still send a report for this spot" y530 | "Next" y571 h80 | dropped | hidden | beside card | pass (`x-nodata-report.png`) |
| No-data, Report pill | AX1 | title y365 | "Next" y559 h92 | dropped | hidden | top-right | instruction dropped, empty band; see #1 (`a-nodata-report.png`) |
| Snapped, long-press (baseline, extra) | XXXL | "8 Avenue, East side" y402, "No standing" chip y488, "between W 31 ST & W 33 ST" y530 | "Park here" y571 h80 | dropped | hidden | beside card | pass (`x-snap.png`) |

Per cell: nothing clipped, overlapped or truncated; every primary is fully on screen (bottom edge 651, 16 pt above the screen bottom) and tappable (AXe described it as a button at that frame); no scroll region exists. Tip-to-card gap measured from frames and screenshots: about 146 pt at XXXL (tip 240, title block top about 386) and about 149 pt at AX1 (tip 200, card top about 349), above the 130 pt floor. After Cancel from the AX1 no-data session the ambient layer and the "ASP in Effect Today" banner returned.

## Acceptance (addendum) checklist
- [x] Legality / message never scrolls, status or no-curb / no-data message visible in all 8 cells.
- [x] Primary visible and tappable in all cells.
- [x] Rows drop by priority: link first, then the instruction line at AX1 (no-curb and no-data); the nearest-curb chip stays.
- [x] Report link dropped at XXXL on SE and at AX1 (the link was absent in every long-press cell, as spec says).
- [x] ASP banner hidden during placement at XXXL and AX1 on SE, returned on Cancel (checked after the AX1 no-data session).
- [x] Locate: top-right at AX1, beside the card at XXXL; it never touches the pin.
- [x] Cross-street line baseline: still UPPERCASE ("between W 31 ST & W 33 ST") while the title is title-cased ("8 Avenue, East side"). Known, unchanged.

## Findings

### Blocking
None.

### Significant
None.

### Minor
- **#1: AX1 no-data card has about 110 pt of empty band between the title and the primary.** Where: SE AX1, "No parking data here", both entry paths (`a-nodata.png`, `a-nodata-report.png`). What: the status slot is empty by design and the instruction line ("You can still save your car at this spot" / "...send a report...") is dropped at AX1, so the card reads as a title, a blank block, then the button. Legality is not at stake (there is none), and the title carries the message, but the dead space looks unfinished. Expected: spec allows the instruction to drop; not a violation. A designer could instead keep the instruction in the status slot when the chip is absent. Owner `@designer` / `@ios-engineer`, follow-up only.
- **#2: Cross-street subtitle still uppercase** (baseline confirm, see checklist). Owner `@ios-engineer`, polish PR in flight.

### Out of scope (logged, not fixed)
- The ambient goal dock on SE at XXXL wraps the "Overnight" label mid-word ("Overnig / ht") in the three-tile row (cold-launch screenshot at XXXL, Manhattan). This is the dock, not the placement card, and it recovers when the dock shows its one-row form at AX1 ("Overnight ... Change"). Owner `@ios-engineer` / `@designer`.

## Not tested, and why
- Snapped state through the Report-pill path (the pin starts on the puck inside the MSG no-curb footprint and a pan to a street was not scripted); the card is the same component as the long-press snapped cell, which passed at XXXL. Snapped at AX1 and far-curb were covered by the PR #155 pass.
- Mid-session Dynamic Type change (PR #155 minor #1, about 5 pt primary overflow) was not exercised.
- Rotated-map cases, pinch, two-finger gestures: AXe fails on this host. Device-only.
- VoiceOver traversal, real SE hardware, sunlight: Kevin's device list.
- Hint pill: shown on the first entry only (seen in `x-nocurb.png`); not re-checked on later entries by design.

## Rig and cleanup
Disk 13 GB free before build (guard 8 GB), 10 GB after. Derived data `~/Library/Caches/wepark-qa-se-dd` removed, SE sim deleted (none remaining), `Constants.swift` reverted, the copied `Config.xcconfig` removed from the worktree. Only this report and the assets are committed.
