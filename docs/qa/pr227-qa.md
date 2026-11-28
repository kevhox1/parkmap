# PR #227 (R35-4 zoom bands) QA Pass 1 - 2026-11-28

**Reviewed:** branch `ios/r35-pr2-zoom-bands` at `1e4ef31e` (stacked on #225 `2161a9c6`), against `docs/specs/r35-map-polish-and-trip-destination.md` PR2.
**Verdict:** PASS with follow-ups

## Summary
The red blanket is fixed and measurably so: before, dashed red curbs rendered 10-12 pt wide; now dashed and solid curbs are within about 20% of the same width at every zoom I measured. Bands, hints, nesting and the flag-off path hold. The zoom-out lag is only partly fixed: nothing is drawn above 0.02, but each settle still costs about 0.7-0.9 s of main thread (finding 1).

## Acceptance checklist
- [x] Three bands (0.012 / 0.020), boundaries inclusive on the lower band - own tests `QA227ZoomBandTests` (`docs/qa/pr227-zoom-band-tests.swift.txt`) + live screenshots.
- [x] Hints "Green curbs only. Zoom in to see the rest." at 0.0128 and 0.0145, "Zoom in to see parking" at 0.025 - screenshots. No hint at 0.0106 or closer (shows the street-cleaning pill as before).
- [x] Green-only band draws green only, green unchanged - code: `filter` keeps `free` untouched, and the green decision is made before the filter in all three paths (live goal, current state, trip). Screenshot at 0.0145 shows green only.
- [x] Nesting untouched - green set is computed exactly as before; the band only drops other groups.
- [x] Zoom-scaled widths, thin at wide zoom - measured below.
- [x] Drive Mode widths unchanged - code only: `curbRenderScale` / `applyCurbStyle` branch on `parent.driveModeActive` to the old `zoomScale`. NOT verified live (no drive session on the sim).
- [x] Tiles not loaded above the cutoff, Stoop only - code (`handleRegionChanged`); the flag-off path is the old call.
- [x] Flag off unchanged - full `WeParkTests` on this head with shipped flags: 3392 tests, 0 real failures. Two known location flakes (`AmbientDrivingLookLocationPostureTests.testRestingFix_...`, `ParkTrackLocationServiceTests.testSingleShotBranch_alsoRecordsTheFix`) failed because my sim had a location set; after `simctl erase` they passed (10/10).
- [x] Dry-run merge into latest `origin/main` (includes #223, #224, #226): clean auto-merge, no conflicts (not re-compiled after the merge). #226 is already merged to main.
- [ ] Zoom-out lag materially reduced - PARTIAL. See finding 1.

## Re-measured stroke widths (my own sim, iPhone 17 Pro, iOS 26.5, 3x, tool `docs/qa/pr227-stroke-measure.swift.txt`)
Pixel-measured from screenshots (dashes by minimum bounding width, solid by area/perimeter). Anti-aliasing costs about 0.3 pt on every number.

| span | intended | solid green | dashed red | dashed / solid |
|---|---|---|---|---|
| 0.0027 | 4.0 pt | 3.7 pt | 3.2 pt | 0.87 |
| 0.0047 | 4.0 pt | 3.9 pt | 3.6 pt | 0.92 |
| 0.0082 | 3.0 pt | 2.8 pt | 3.0 pt | 1.07 |
| 0.0145 (green only) | 2.0 pt | 1.8 pt | none | - |

Before (PR1 head, same spots): dashed red 9.9-12.3 pt, solid green 4.8-5.7 pt, i.e. dashed was about 2.1x solid. So the 2.35 inflation is real and the fix lands. The constant is slightly high at close zoom (dashes slightly thin) and slightly low at 0.008 (slightly thick); no zoom-dependent trend large enough to matter. I did not measure at 0.011-0.012 in numbers; the 0.0106 screenshot shows red and green visually the same weight.

## Findings

### Significant
- **#1: zoom-out lag is only about half fixed (the cost is the goal block, not the drawing)**
  - Where: `ContentView.rebuildOverlays`, the DM-2 goal block above the band guard (`resolveParkAndForgetViewport` x 3 ladder rungs over every loaded segment, strict-green).
  - What: pinching out from Penn Station, main-thread `rebuildOverlays` time per settle. PR1 head (machine load about 10-30): 0.0145 -> 417 + 693 ms; 0.0255 -> 530 + 1149 ms; 0.0448 -> 941 + 988 ms; 0.0787 -> 753 + 1186 ms (two rebuilds per step: one on settle, one when the new tiles land; segments grow to 9,555). PR2 head (machine load 90-200, so inflated): 0.0255 -> 876 / 782 ms; 0.0448 -> 858 / 682 ms; 0.0787 -> 769 / 793 ms (one rebuild, segments pinned at 5,198). So the second rebuild and the tile decode are gone, but a rebuild that draws nothing still costs about 0.7-0.9 s.
  - Expected: spec says the earlier cutoff cuts lag; the builder's note says 0.9-1.4 s per step before. A zoomed-out settle with nothing to draw should be near free.
  - Suggested fix (for the owner): in Stoop, when band is `.off`, skip the For-days Auto ladder resolve and classification (they feed only the dock tile; it is already frozen on last-close tiles), or cache it per (window instant, tile set).
  - Caveat: load on the Mac was far from clean; numbers are directional, not exact. Verify on device.
  - Owner: `@ios-engineer`

### Minor
- **#2: selected red curb is not dash-corrected.** `styleSelectedLine` still uses `CurbLineStyleV2.apply` (no `/2.35`) for the dashed selected curb, so a selected red curb is about 2.35x fatter than its scale implies. Not verified live (no curb selection driven). `MapViewRepresentable.swift` `styleSelectedLine`.
- **#3: no "Loading curbs" on zoom back in after a far pan.** While zoomed out the tile set is frozen; when you zoom in somewhere else, the first rebuild runs on the old tiles (nothing visible there), no loading pill since `segments` is not empty, then the tile arrival rebuild draws. Honest (no fake green), just a short blank. Not driven live.
- **#4: the dock still says "Green curbs are free from now until 7 AM" with nothing drawn at 0.025.** Hint pill covers it; mild.

### Builder caveat: "For days Auto reflects the last close tiles while zoomed out. Is that honest?"
Mostly yes. Nothing is drawn above 0.02, so the number can never contradict visible green. The date describes the last area you looked at closely, not the area on screen, and nothing says so. Before this PR it tracked the viewport up to 0.5. I rate it acceptable for this PR; if Kevin sees "until Tue 12/1" jump when he zooms back in somewhere else, that is why (I saw it vary with zoom: Sun 11/29 at close zoom, Tue 12/1 at 0.0145, expected, same as before the PR).

## Smoke tests run
- Built and ran on my own sim with Stoop + drive-mode flags flipped locally (never committed), pinch-zoomed out from Penn Station and read the screenshots: 0.0047, 0.0082, 0.0106 (full band, thin dashed red + green, no blanket), 0.0128 / 0.0145 / 0.0155 (green only with hint), 0.025 (off, "Zoom in to see parking"). I could not set exact 0.0035 / 0.011 / 0.016 / 0.03; used these nearest spans.
- Full `WeParkTests` with shipped flags: pass apart from the two known flakes, which pass on a clean sim.
- 5 own tests added (boundaries, width sweep 0.0005-0.05 stays within 1.5-4.5 and green-only at least 2.0, filter never adds green, hints, launch span inside cutoff): pass.

## What's working
The band logic is small, pure, and tested; the green decision is untouched; the screenshot at 0.0106 reads the way the spec wants (curbs about a sixth of the street). Hints are plain and correct.

## What Kevin should check on a device
1. The 2.35 dash constant is a sim measurement. Eyeball it at about 1 km tall (a few Midtown blocks): red dashes and green lines should look the same thickness. If red looks clearly fatter than green, raise `dashedRenderInflation`; if thinner, lower it. Check once at 0.004 and once at 0.008.
2. Zoom out smoothly from 400 m to the whole of Midtown: how long does the map hang when it passes 2 km?
3. Pinch out, pan far, pinch in: any blank gap or wrong green?
4. Drive Mode: curbs should look the same as before this PR.
