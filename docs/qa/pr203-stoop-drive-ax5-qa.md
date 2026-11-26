# PR #203 Stoop drive mode at accessibility sizes: QA Pass 1 (2026-11-26)

**Reviewed:** `fix/stoop-drive-ax5` at `9845a45b`, merged locally with `origin/main` (`7570733b`; clean merge, HANDOFF.md + version bump only), against `docs/qa/pr201-stoop-phase3-drive-qa.md` findings #1/#2 and the PR's acceptance list.
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
The compact one-row-per-side layout, pinned actions and single-row street/End header do what the PR says: on iPhone SE (3rd gen, independently re-shot at AX5) and in the PR's SE and Pro Max shots both verdicts are visible together, never truncated, with Park here / Report / Voice pinned and large. The type cap is a reasonable, tested trade for a glanceable driving surface. The one real gap is the arrival sheet at AX5 on SE, where the primary button is half below the fold: a 🟡 follow-up, not a blocker. Flag-off paths are untouched.

## Acceptance checklist
- [x] Both drive sides visible without scrolling, verdicts never truncated, SE and Pro Max: viewed PR shots `b5-{both,nodata,neither,unsure,dest,unclear,muted}-ax5-{se,max}`, `b5-meter-ax5-max`, AX1/AX3 spot checks; independently re-shot `-wp3Showcase both|nodata|arrive` at `accessibility-extra-extra-extra-large` on my own SE sim. Verdict wraps by words ("Park until Mon / 9:00 AM"), "No sign data" / "No parking" / "Unclear sign" / "Checking" all fully shown.
- [x] Actions pinned and large: Park here full width (~80 pt), Report + Voice on one row (~70 pt) on SE; not inside the scroll view (`WPDriveBottomV2`).
- [x] Street pill clear of status bar: top padding is `paddingForBannerState(.aspInEffect)` (100 pt), pill sits well below the SE status bar and the Pro Max island.
- [x] Scroll indicators visible: `WPFitScroll` `showsIndicators: true` (WPDriveV2.swift:332). Nothing overflows in the drive-bottom states I saw, so the indicator itself was not exercised.
- [x] `b5-nodata-ax5-*` shows the no-data right side ("No sign data"); reproduced independently.
- [x] Tint world ring: `WPDriveTintPolygon.worldRing` (MapViewRepresentable.swift:~236) is a closed ring at +/-85 lat with edges <180 deg longitude (tested). Added/removed only in `applyDriveMapStyle` (line ~1566, remove-then-insert, so never duplicated; gated on both flags); inserted at index 0, `.aboveRoads`, and every curb polyline is added later at `.aboveRoads`, so the tint is beneath. No leak across start/end: note `applyDriveMapStyle(true,nil)` is also the ambient look entry (ContentView.swift:5785/5800), so the tint is intentionally present whenever flag-on ambient or drive is active and removed only by `active == false`; repeated calls stay at exactly one polygon.
- [x] Showcase window: whole file is `#if DEBUG` (WPPhase3Showcase.swift:15); `ContentView` mount is also in a `#if DEBUG` Group. Live `v2DriveTopChrome` padding unchanged (only the showcase `.padding(.top, 8)` became `paddingForBannerState`).
- [x] Flag-off unchanged: `WPDriveV2.swift` views, tint and showcase are flag-on/DEBUG only; `DrivingContextService` change is a comment only.
- [ ] Arrival sheet at AX5 on SE: known gap, see finding #1.

## Type cap judgement (`maxDriveTypeSize`)
Accept. Brief: "Dynamic Type through the largest accessibility sizes without truncating critical information", context: glanceable, large targets. At AX2 (AX1 on SE) the drive surface is still accessibility-sized (28 pt bold verdict scaled, 50-80 pt targets) and both verdicts + actions fit one screen with nothing cut; uncapped AX5 on an SE could not fit both sides, the street and the actions without scrolling, which is worse for a driver than slightly smaller text. VoiceOver is unaffected and the cap is a pure tested function. Caveat worth a product note: AX3-AX5 users get no larger drive text than AX2 (AX1 on SE), so the largest-type users see the least scaling; the PR is upfront about this. Optional follow-up: offer a drive-only "larger text" setting if user feedback asks.

## Findings
### Blocking
None.
### Significant
- **#1 (yellow): Arrival prompt at AX5 on SE leaves the primary "Park here" button half below the fold.** Where: `WPArrivalPromptV2` (WPDriveV2.swift ~430-485), scrolling sheet. What: after "You've arrived. Park here?" header, the left-side card and "Right side: no parking.", only the top of the yellow button shows (my SE shot `docs/qa/assets/pr203-qa/qa-live-arrive-ax5-se.png`); "Keep looking" needs a scroll. On Pro Max it fits, but "Keep looking" is cut at the edge. Expected: the decision buttons are the point of the sheet. Severity rationale: confined to the SE class at the biggest sizes and flag-on; the user is arriving (slow/stopped) and the half-visible button plus `.basedOnSize` scroll bounce hint at more, so it is usable but not glanceable. Fix idea: pin the two buttons below the scrolling content (as drive-bottom does) or shrink the AX title. Owner: `@ios-engineer`. Follow-up, not a merge blocker.
### Minor
- **#2 (green):** "Park, no meter running in your window" (`WPDriveVerdict.compactLine`, WPDriveLogic.swift) wraps to 3 lines on Pro Max AX5 (`b5-meter-ax5-max.png`). Fits, but the caveat is wordy for a glance; consider "Park, no meter now".
- **#3 (green):** `WPPhase3Showcase.window` is a static never torn down; DEBUG only, harmless.
- **#4 (green):** `UIScreen.main.bounds` (deprecated) used for the cap/scroll height (WPDriveV2.swift:353/364/419/484); pre-existing style, fine on iPhone, would mis-size under split/Stage-style windows.
### Out of scope
- Real moving-map drive with flags on (tint under curb lines at speed, tint at low zoom performance): not verifiable in sim; PR also says not verified. Recommend Kevin's next on-device drive checks the tint and the arrival sheet.

## Smoke tests run
- Merged result, scheme `WePark`, `-parallel-testing-enabled NO -jobs 4`, private iPhone SE (3rd gen) sim: **3066 tests, 1 skipped, 0 failures** (8 DriveAXLayoutTests lines passed). No flakes hit.
- Builds: WeParkClip, ClipLiveActivities, WeParkLiveActivities: BUILD SUCCEEDED.
- Live DEBUG showcase on own SE sim at AX5 (`xcrun simctl ui content_size accessibility-extra-extra-extra-large`, location permission granted, screenshots Read): `both`, `nodata`, `arrive` states as described above. Used the DEBUG showcase only (no flags flipped; it renders the real `WPDrive*V2` views from fixtures). Not a full live-map mount-chain run; the PR touches `MapViewRepresentable.swift` only in the tint polygon/ring code, which I verified by reading, and the showcase window cannot be exercised flag-off (DEBUG-only, file guard).
- Pro Max: not run live (one sim at a time on this machine); judged from the PR's `-max` shots.

## What's working
Clean, well-bounded fix with a pure, tested cap function; honest PR body (calls out cap decision and the arrival gap); the compact row design reads instantly at AX5 and the dropped secondary text never turns a non-green side green (tested).

**MERGE-WITH-FOLLOWUPS** (follow-up: finding #1)
