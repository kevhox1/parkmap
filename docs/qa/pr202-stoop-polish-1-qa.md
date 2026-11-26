# PR #202 Stoop polish batch 1 QA

**Reviewed:** branch `fix/stoop-polish-1` at `5d202ccd`, merged locally with `origin/main` (6068b7ce, #201). Merge was clean, no conflicts (not pushed).
**Verdict:** MERGE-WITH-FOLLOWUPS

## Build and test (merged result)
- All 4 schemes build: WePark, WeParkClip, ClipLiveActivities, WeParkLiveActivities. 0 errors.
- Full WePark suite, `-parallel-testing-enabled NO -jobs 4`: 3060 run, 1 skipped, 0 failures on the PR code. (The 2 failures in the first run were my own scratch DST test, removed before this report.)
- Live flag-on sim smoke: NOT run (1-min load 56-75, above the 40 limit). Frames were judged from the committed screenshots only.

## Findings
### Significant
- **#1 `nextMeterStart` is wrong on DST days.** `WPCurbSheetLogic.swift` (`nextMeterStart`): `cal.date(byAdding: .minute, value: tr.start, to: startOfDay)` adds elapsed minutes, not wall-clock minutes. A scratch test with a daily meter 8:00 AM-7:00 PM compared it to a minute scan.
  - From Sat 2026-03-07 10 PM: returns 9:00 AM EDT. The scan gives 8:00 AM.
  - From Sat 2026-10-31 10 PM: returns Nov 2 8:00 AM. The scan gives Nov 1 8:00 AM, so the whole Nov 1 meter is skipped. The sheet then says "Free until Tomorrow+1" when a meter starts the next morning. That is a false parking statement.
  - Cost: about 2 days a year, and only when `from` is within a day of the change. Fix: use `cal.date(bySettingHour:minute:second:of:)` as `timeRangeOverlaps` does. Add a DST case to the minute-scan test, which has none.
  - Owner: `@ios-engineer`.

### Minor
- **#2 Building shading in the light frames.** `b6-idle-light.png`, `curb-dont-light.png` and `highlight-dont-light.png` still show shaded, shadowed building blocks. I can't tell whether that is the base-map footprint rendering or `showsBuildings` not applying in the light frames. The dark frame is plain footprints. Needs a live look. Owner: `@ios-engineer`.
- **#3 The sweep test has no DST case.** It covers all surfaces for "until <non-time>" (11 curb kinds x 4 windows x neighbor report on/off), but it doesn't test `nextMeterStart` accuracy on DST days.

## Checklist
1. Garble gone. Fixed through `bigIsTime`/`freeLine`, the drag bubble `.soon where !bigIsTime` case, and the neighbor sign line. The sweep test asserts every "until " is followed by a time word. I found no other `Free until` producers outside `WPCurbSheetLogic` besides the existing `.soon` bubble case. Pass.
2. Car callout: `carCallout` passes `windowEnd: nil`, with neighbor reports applied. An active filming report gives "Blocked for filming". It reads the same as the no-window sheet, so it can't be greener. Pass. Wording "Meter on this curb. Check the meter." is natural.
3. `WPSearchCountKey` holds the `Set<String>` of loaded tiles, and the test covers an equal-count swap. Pass.
4. `nextMeterStart`: day-of-week is handled by `rangeActive` at the start instant. Overnight windows and an `all day` (0,0) range are OK in non-DST scenarios, and the minute-scan test passes on 6 rule sets. DST fails (finding #1).
5. Window boundary: the engine is half-open (`rStart < windowEnd && rEnd > windowStart`), documented as PWA parity. A restriction starting exactly at the window end is not an overlap, so the map shows green and the sheet now agrees. The sheet's park/soon decision is now just `isParkable` for the window, which is monotone in window end, so green nests (A Few Hours ⊇ Overnight ⊇ For days). Product caveat: "Overnight until 7 AM" over a 7:00 AM street cleaning means the car must be gone at 7:00 sharp. This is by existing design and consistent. The copy says "Free to stay until 7:00 AM", which is honest. Pass.
6. Base map: `showsTraffic = false` and `showsBuildings = false` are applied only under the flag. `setShowsBuildings` returns `show && !flag`. Drive mode (#201) still calls `setShowsBuildings(!active)`, so buildings stay off after leaving drive mode with the flag on, and are restored with the flag off. `applyDriveMapStyle` is untouched. See #2 on the screenshots.
7. Hint and AX row: `parkDragHintSeen` is set in `handlePinDropped` only under the flag, and the hint is gated on it. `v2PlaceCarAtUser` goes through the same `placeAt`, which uses the same verdict and confirm card. Without location it returns false and the caller opens search. Index prep also runs at AX sizes. Pass. Not live-verified.
8. Highlight: `v2HighlightState` forces `.restrictedNow` on an active neighbor restriction. Underlays are removed on each update, so repeated taps don't leak. They are cleared when the selection is nil, and zoom restyle handles them. The trip-plan path is unchanged. Pass.
9. Frames are not black and show the right states: don't sheet with "Park here anyway", the idle token with the "Drag to a curb to park" hint, and the no-data dark sheet. The highlight frame shows the casing and dashed line. Pass (see #2).
10. Flag off is unchanged: every changed branch is gated on `designSystemV2Enabled`, except the `parkDragHintSeen` `@AppStorage` declaration, which is inert. Pass by reading. The flag-off before/after frames were not compared.

## Verdict
MERGE-WITH-FOLLOWUPS. Follow up on #1 (DST false-green, small fix) and #2 (live check of buildings).
