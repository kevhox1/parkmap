# PR #154 QA: Settings row in the More sheet (#37 ⑦), 2026-11-23

**Reviewed:** branch `feat/more-settings-row` at `7b90ac5d`, against `docs/open-items.md` row 37 ⑦ and `docs/design/first-run-onboarding-design.md` §3.1
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
The Settings row does what the PR says. It is the last row in every flag and state combination, it uses `gearshape.fill` with the right subtitle, and it opens the same `.settings` sheet as Search's gear through the existing `activeSheet` swap. No second presentation path was added. The AX5 failure the builder saw was a harness artifact, not an app bug. One discoverability follow-up: at the single `.medium` detent the row sits below the fold even at `large` Dynamic Type.

## Acceptance criteria checklist
- [x] Settings is always the LAST row. LIVE (More at `large` and AX5) and CODE (`rows.append(.settings)` is the final statement of `moreMenuVisibleRows`; tests assert `rows.last == .settings` across flag combinations).
- [x] Icon `gearshape.fill` and subtitle "Reminders, help, and app info". LIVE screenshots and the AX tree label "Settings, Reminders, help, and app info".
- [x] Row is 64pt minimum. CODE (shared `rowLabel` `minHeight: 64`); LIVE at `large` it renders at about that height.
- [x] Tap opens Settings via `activeSheet = .settings`, with no second presentation path. LIVE and CODE (`handleMoreMenuSelection`; one `case .settings` assignment).
- [x] Dismissing Settings returns to a clean map. LIVE at `large` (swipe-down; rest-state dock and rail intact).
- [x] AX5: More scrolls and Settings is reachable and opens. LIVE.
- [x] Subtitle matches Settings contents. LIVE: Settings shows Help (Parking 101, Help & FAQ), Notifications, and Move-Your-Car Reminders; About is per the file's section comments (not scrolled to). Account deletion stays flag-gated and is not promised.
- [x] Flag off: More is unreachable and the Search gear opens Settings. LIVE (flag-off build: no More button; gear tap opened Settings).
- [x] Flag-off guards intact. CODE: the diff touches only `MoreMenuRow`, `moreMenuVisibleRows`, and one switch case in the flag-on handler. `driveModeDefaultEnabled` is untouched (my local flip was reverted; `git status` clean).
- [x] Doc note present. CODE: dated row-8 note in `first-run-onboarding-design.md`.
- [x] Test updates are coherent with the code (`MoreMenuSheetTests`, `MinimalAmbientLayoutTests`). CI is green; I did not run the suite.

## Findings

### Blocking
None.

### Significant
None.

### Minor / nit
- **#1: Settings is below the fold at the `.medium` detent even at `large` type**
  - Where: `ContentView.moreMenuSheetContent` (`.presentationDetents([.medium])`) with `MoreMenuSheet`'s `List`.
  - What: In the common no-parked-car state at `large`, only Report, What the colors mean, Parking 101, and the Show-all toggle are visible. Settings is row 5 and needs a scroll. The only cue is the scroll indicator. Once scrolled, the row sits comfortably above the home indicator.
  - Expected: Order and presence are per spec (satisfied). The spec does not require visibility without scrolling, so this is a discoverability follow-up, not a defect.
  - Suggested follow-up: add `.large` to the More detents, or accept scroll-to-reach.
  - Owner: `@ios-engineer` (with `@designer` call)
- **#2: Settings sheet has no Done button; swipe-dismiss only** (pre-existing, not introduced here).
  - Owner: `@ios-engineer`, if desired.

### Out of scope (logged, not fixed)
- Parking 101 now appears both as its own More row and inside Settings > Help. This is consistent with the spec.

## AX5 tap explanation (harness artifact, not an app bug)
- With More just opened at AX5 (unscrolled), the Settings row is not in the accessibility tree. `describe-ui` has no match, and `axe tap --label "Settings, ..."` fails with "No accessibility element matched". A bare `--label "Settings"` also fails.
- At `large`, unscrolled, the lazily realized row does appear in the tree with an off-screen frame. A label tap resolves to that frame's centre, below the screen edge. That lands outside the sheet and dismisses it, which matches the builder's symptom. I could not reproduce the exact below-screen resolution at AX5 (the element was absent), so the AX5 mechanism is inferred from the `large` behavior.
- After a real scroll (8 swipes) at AX5, the row frame is y≈555 to 814pt on an 874pt screen. That leaves about 60pt of clearance, past the ~34pt home-indicator zone. The label tap then resolved to (201, 684) and opened Settings (AX5 layout, Help rows wrapped).
- A real user can scroll the row fully clear of the home indicator. No detent or inset problem was found.

## Smoke tests run
- Flags-on sim build with `driveModeDefaultEnabled=true` flipped locally and reverted afterwards; onboarding suppressed. LIVE.
  - `large`: More opens; order Report, What the colors mean, Parking 101, Show all rules, Settings. After scroll, Settings is last with gear icon and subtitle. Tap opens Settings. Swipe-dismiss returns to the clean map.
  - AX5: More opens and scrolls; the tap behavior above; Settings opens.
- Flags-off rebuild (flag false) at `large`. LIVE: no More button; the Search gear opened Settings.
- Code review of the five changed files. CODE.
- Cleanup: simulator shut down, content size reset to `large`, derived data deleted, `Config.xcconfig` not committed.
- Not run: unit test suite (CI ran it), SE/Pro Max sizes, device VoiceOver, a parked-car/onboarding-replay row-set live check (covered by unit tests only).

## What's working
- Minimal diff with a single source of truth for row order, plus a dated design-doc note.
- Reuses the existing `.settings` sheet path with no new presentation machinery.
- The subtitle is honest about what Settings contains.
