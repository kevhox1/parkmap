# Curb-pin placement FLIP SMOKE, QA Pass 1 (live simulator), 2026-11-23

**Reviewed:** `origin/main` at `ed45ef85`, built locally with BOTH `curbPinPlacementEnabled` and `driveModeDefaultEnabled` flipped to `true` (local edit, discarded). Against `docs/open-items.md` row 37 item 8, `docs/qa/pr143-a3-curb-pin-placement.md` (pass 1 + pass 2 Mac smoke scripts), `pr140` P2-2, `pr147`, `docs/design/curb-pin-placement-design.md`.
**Rig:** iPhone 17 sim (402x874, iOS 26.5) and a temporary iPhone SE 3rd gen sim (375x667). AXe 2.1.1. Every screenshot was read.
**Verdict:** NOT FLIP-READY. One blocker: at accessibility sizes (AX1 and up) the placement card hides the street line and the status chip, and at AX5 it overlaps itself. Everything else I could reach on the simulator is clean or minor. If Kevin decides AX1+ users are acceptable at flip time, the rest is FLIP-READY-WITH-FOLLOWUPS.

## Summary
The core feature works live and first try: ambient-to-placement entry (pitched to flat, pan, one `setRegion`) lands the seed under the needle tip with no visible jump, exit restores the ambient camera exactly, out-of-coverage shows "No parking data here" immediately on both entry paths, cold-launch instant entry resolves within about a second, and the card top and Apple logo hold still across every data state. The exposed problems are all Dynamic Type: P2-1 from PR #143 QA is real on the SE (status chip clipped at Large, hidden at XXXL and AX1), and the same clipping shows up on the 874 pt phone from AX1 upward. Multi-touch (rotate, pitch) is not drivable with AXe on this host, so the rotated/pitched no-curb save is unverified.

## Acceptance criteria checklist

- [x] Phase 0, flag-off baseline: legacy gear/search bar, ASP banner, Report pill, legacy "Park here?" long-press dialog with Park here / Cancel, close-zoom. Verified by screenshot (`/tmp/qa/p0-cold.png`, `p0-lp.png`). Note: the flag-off cold launch at default zoom showed no polylines and no Park Until pill; I did not chase it (not part of this smoke, tiles were still loading; flag-on screenshots show polylines fine).
- [x] Flag-on cold launch renders the full overlay layer (toolbar Search/More, ASP banner, Start Driving, goal dock, blue puck, Maps logo above dock) in the pitched ambient look. Verified by screenshot.
- [x] #147 entry: long-press, then pin seed under the tip, no jump (see table row 1).
- [ ] AX card layout, FAILED. See finding #1.
- [ ] P2-1 SE card, FAILED at Large (chip clipped). See finding #2.

## Checklist table (every script item)

Legend: LIVE-pass, LIVE-fail, CODE (not exercised live, relying on prior code QA), NOT-SIM-TESTABLE (Kevin device).

| # | Script item | Result | Notes |
|---|---|---|---|
| 1 | Pitched ambient to placement (#147), flag-on both | **LIVE-pass** | Long-press in pitched ambient look. Screenshot taken 0.4 s after the press already shows the finished flat placement view (no intermediate frame captured, no jump). Needle tip measured at y=350 pt, which is exactly 0.40 x 874. The curb highlight and snap line sit right at the tip. Cancel returns to the same pitched ambient camera as before entry. Re-entry at the same spot gives the identical frame. I could not prove the pressed coordinate equals the seed to the metre (no ground truth), only that the seed is on the tip and the camera is deterministic. |
| 2a | Out of coverage, long-press | **LIVE-pass** | Sim fell back to Cupertino (Apple Park). "No parking data here / You can still save your car at this spot", Save car here enabled, shown within 0.3 s. |
| 2b | Out of coverage, Report entry (More, Report) | **LIVE-pass** | "No parking data here / You can still send a report for this spot", Next enabled, map did not fly, Next opened the ReportSheet ("Reporting at current location"). Caveat: sim location equalled the map position, so "report uses the pin, not the fix" is not distinguishable here (CODE for the segment:nil / coordinate source). |
| 2c | Seed out of coverage, pan into Manhattan, card recovers | CODE | Not run (needed a pan across a long distance). |
| 3 | Slow-tile cold launch, Loading up to 3 s | **LIVE-pass (partial)** | Kill, relaunch, More, Report at about 3 s after launch: pin grey (loading) for under 1 s then "No curb here / Nearest curb 230 ft" with Next enabled; no input needed. A forced slow-tile condition was not simulated. |
| 4 | Index cache / race | **LIVE-pass (partial)** | Cold launch instant entry resolves in about 1 s with no pan. Re-entry in the same spot shows no Loading flash. Cache-miss in a new area and console retry check not run. |
| 5 | Card height invariance | **LIVE-pass** | iPhone 17: card top 478 pt (display y 1410) and Maps logo position identical across snapped, no-curb with chip, no-curb far curb, noData, loading. Report-entry card sits about 1 pt lower than the Park-entry card (no link row), negligible. Two-line cross street and long status string not exercised (see Out of scope). |
| 5b | Card top >= tip + 130 | **LIVE-fail, marginal** | iPhone 17: tip 350, card top 478, gap 128 pt. SE: tip 267, card top 396, gap 129 pt. 1-2 pt under the design number. See finding #4 (minor). |
| 5c | SE: status chip fully visible without scrolling (P2-1) | **LIVE-fail** | Chip is half cut off at Large. See finding #2 and SE numbers below. |
| 6 | Margins / logo before, during, after | **LIVE-pass (partial)** | During: Maps logo sits just above the card (display y 1340 vs card top 1410) and does not move between states; ghost did not shift when states changed. After: logo returns above the dock, ambient camera identical to before entry. A true before/during comparison on a notch device with the dock disappearing: Dynamic Island iPhone 17 screenshots show the logo lifted correctly. Not re-measured pixel-for-pixel. |
| 7 | Taps after exits | **LIVE-pass (partial)** | After Cancel: ambient restored, dock live. After Park (no-curb save): car pin tappable, My Car sheet opened (car detail), closed, long-press re-enters placement. Cancel with an existing car keeps the car. Not exercised: Next-exit, Report link exit, sheet-over-session (notification, invite), Drive start attempt, background/foreground, replace-then-Cancel beyond the one above, block tap after exit. |
| 8 | Deep link mid-session | CODE | No way to inject a notification here. |
| 9 | Ambient tilted look: pan-then-tighten, no hijack, exit recenter | **LIVE-pass (partial)** | Exit restored the pre-entry camera with no late jump seen in two screenshots 2 s later. Cold-launch hijack and arrow-off-after-exit not verified. |
| 10 | First-ever park rationale ordering | **LIVE-pass** | Committing a first park showed "Stay ahead of street cleaning" (Enable Reminders / Not now) over the map, not overwritten; Not now returned the ambient dock. Double-tap-Park and old-reminder cancellation not run. |
| 11 | Background mid-pan | CODE | Not run. |
| 12a | Dynamic Type Large | **LIVE-pass (17), LIVE-fail (SE)** | 17: card complete. SE: chip clipped. |
| 12b | XXXL | **LIVE-pass (17), LIVE-fail (SE)** | 17: street + chip visible; Park here and link pinned below, card scrolls (2 pages). SE: street and chip hidden. |
| 12c | AX1 | **LIVE-fail** | Street line and chip not visible, no-curb instruction and Nearest-curb chip not visible. Finding #1. |
| 12d | AX3 | **LIVE-fail** | Same, bigger. Finding #1. |
| 12e | AX5 | **LIVE-fail** | Card overlaps itself, needle 18 pt above card. Finding #1. |
| 12f | Pro Max, Reduce Motion, VoiceOver cycling | NOT-SIM-TESTABLE (Kevin device) / CODE | |
| 12g | Hint pill shows once only | **LIVE-pass** | Shown on first entry ("Drag the map to place the pin"); absent on second entry in the same run, and absent after a kill+relaunch. SE first entry shows it (fresh install). |
| 13 | Community on with pending "did it pass?" card | CODE | Not reachable. |
| 14 | Compile watch-list | **LIVE-pass** | Clean build on both flag states (33 s incremental). |
| M1 | Rotated/pitched no-curb save, report coordinate vs reticle | **NOT RUN (tooling)** | `axe gesture rotate` and two-finger swipe both fail on this host (`DecodingError.keyNotFound: 'displays'`, no input sent; pinch fails identically). Not a product result. Kevin device or a fixed AXe. |
| M2 | Find-me deferral (no cached fix, then session, then Cancel) | CODE | Not run. |
| M3 | Sunlight / outdoor legibility of highlight and card | NOT-SIM-TESTABLE (Kevin device) | |
| M4 | 2 m side-commit dead-band feel verdict | NOT-SIM-TESTABLE (Kevin device) | |
| M5 | Real VoiceOver traversal of retitled adjustable element and curb list | NOT-SIM-TESTABLE (Kevin device) | |
| M6 | Real GPS accuracy and fix freshness | NOT-SIM-TESTABLE (Kevin device) | See finding #5 for one thing to look at. |

## Measured numbers

iPhone SE 3rd gen (375x667 pt), `curbPin` flag on, snapped state, Report link row present:

| Size | Tip y | Card top | Gap (tip to card top) | Street line | Status chip | Park here frame | Scroll region |
|---|---|---|---|---|---|---|---|
| Large | 267 | 396 | **129** | visible | **clipped, about half** ("Free" cut at the scroll edge, y 500 to 521 of about 38 pt) | y 538, h 60 | 2 pages |
| XXXL | 267 | 396 | 129 | **hidden** | **hidden** | y 504, h 79 | 3 pages |
| AX1 | 267 | 396 | 129 | hidden | hidden | y 480, h 92 | 7 pages |

Card top is constant at 396 on the SE across sizes (good), but the pinned Park here + Report link rows eat the scroll region, so the info rows get about 90 to 110 pt and lose.

iPhone 17 (402x874): tip 350, card top 478, gap 128 at Large. Large and XXXL show street and chip. AX1 / AX3 / AX5 (simctl names `accessibility-medium`, `-extra-large`, `-extra-extra-extra-large`): street and chip hidden; AX5 card top moves up to about 368 (gap 18).

## Findings

### 🔴 Blocking

- **#1: Placement card hides the street line and status chip at AX1 and larger, and overlaps itself at AX5**
  - Where: placement card (`CurbPlacementCard` scroll region with pinned Park/Save + Report link), iPhone 17 and SE.
  - What: At AX1, AX3 and AX5 the visible card shows only the title ("8 AVE · East side" or "No curb here"), a blank band, the primary button and the Report link. The "between W 31 ST & W 33 ST" line, the Free/restricted status chip, the no-curb instruction line and the Nearest-curb chip are not visible (they sit behind the pinned buttons or below the scroll fold; the scroll indicator reports 3 to 12 pages). So an AX user sees "Park here" without seeing whether the spot is legal, the very thing the card exists to show. At AX5 the card also grows to about 368 pt top (needle only 18 pt above the card), the title is cut off by the Save car here button, the Nearest-curb chip frame (y 802) lands on the Report row, the Locate button overlaps the car pin, and the Cancel pill overlaps the two-line ASP banner. Pin-to-card clearance of 130 is not met.
  - Expected: design requires the card at accessibility sizes to keep status readable; open-items 3 and PR #143 smoke item 12 list AX1/AX3/AX5 as a pre-flip check.
  - Repro: set `accessibility-medium` (AX1), long-press on a street at (136,190) in Manhattan, read the card. Compare Large and XXXL where it is fine on the 17. AX5: `accessibility-extra-extra-extra-large`, long-press at (136,330).
  - Screens: `/tmp/qa/p1-ax1-snap.png`, `p1-dt-accessibility-extra-large.png` (AX3), `p1-dt2-accessibility-extra-extra-extra-large.png` (AX5).
  - Owner: `@ios-engineer` (with `@designer` for the AX card spec; the goal dock got an AX addendum in PRs #152/#153, the placement card has none).

### 🟡 Significant

- **#2: P2-1 confirmed on the SE: status chip clipped at Large, hidden at XXXL and AX1**
  - Where: same card, 667 pt phone.
  - What: At Large the Free chip is cut roughly in half by the pinned Park here button; at XXXL and AX1 street and chip vanish. The 17 (874 pt) is fine at Large and XXXL. Any phone shorter than about 800 pt at default size is affected. Card height is constant (good) but the pinned rows take the room from the info rows.
  - Expected: "with the link row, is the status chip fully visible without scrolling" (PR #143 pass 2): No.
  - Repro: SE sim, Large, long-press a street at (110,230), read card (`/tmp/qa/se-large.png`).
  - Owner: `@ios-engineer` (shrink link row, move it into a scroll row, or slim the title to free about 25 pt on SE).

### 🟢 Minor / nit

- **#3: "Drag the map to place the pin" hint pill overlaps the top of the pin balloon on the SE.** Pill bottom about y 212 pt, balloon top about 207 pt, so about 5 pt of the pin head is covered on first entry (the needle tip is clear). On the 17 there is a clear gap. Once-only behaviour is correct. Owner `@ios-engineer`.
- **#4: Tip-to-card gap is 128 pt (17) and 129 pt (SE), design asks 130.** 1 to 2 pt, visually invisible, only matters if the number is a hard requirement. Owner `@ios-engineer` (or relax the design number).
- **#5: Report-entry pin is not on the blue puck.** After a cold launch in Manhattan (Report via More), the seed pin tip sat about 19 pt (about 3 m at this zoom) above the user puck, consistently across two runs. The sim fix may have been stale at entry or the seed may come from a cached fix; with real GPS a few metres of puck/tip offset is plausible noise. Check on device with a live fix; not a flip blocker.
- **#6: Card title is uppercase street text ("8 AVE · East side"), A11y label for the card reads "Parking spot" while the visible title is the street.** Known designer polish item (open-items 8); the label mismatch is for Kevin's VoiceOver pass.

### 💡 Out of scope (logged, not fixed)

- Flag-off baseline cold screenshot at default zoom showed no polylines and no Park Until pill (tiles not loaded yet at 8 s). Re-verify in a flag-off smoke that is not about curb-pin.
- Two-line cross-street and long status strings, Next-exit tap matrix, background/foreground, sheet-over-session were not exercised for lack of injection tooling. A script for the next smoke would need deep-link and notification injection.
- The sim lost its Brooklyn location on relaunch and fell back to Cupertino (which turned out to be a usable out-of-coverage case).
- Disk dropped from 7.3 GB to 4.8 GB while the SE ran; derived data deletion recovered it to 5.3 GB.

## Smoke tests run
- Built twice (flag-off, then flag-on) with xcodebuild into `~/Library/Caches/wepark-qa-curbpin-dd`; both BUILD SUCCEEDED.
- Flag-off: cold launch screenshot, legacy long-press dialog screenshot (read both).
- Flag-on, iPhone 17: cold launch; long-press entry (early and settled screenshots); Cancel; re-entry; pan to no-curb; no-curb Save car here; rationale sheet; car-pin tap; replace flow and Cancel; Cupertino long-press; Report entry out of coverage and Next; Manhattan cold-launch Report entry at about 3 s and 5 s; Large, XXXL, AX1, AX3, AX5 cards (frames via `axe describe-ui` plus screenshots).
- SE: Large, XXXL, AX1 with frames and screenshots.
- AXe multi-touch (rotate, pinch, two-finger swipe) attempted, tool error.

## What's working
- The #147 fix holds live: flatten plus pan in one `setRegion`, needle tip at exactly 0.40 of screen height, no visible jump, and exit restores the ambient pitched camera pixel-for-pixel.
- Out of coverage is handled on both entry paths with usable CTAs; no stuck Loading.
- Card top and Maps logo do not move between snapped, no-curb, far-curb and noData states, nor between Dynamic Type sizes (the layout cost is paid inside the card, which is the problem in #1/#2, but the position invariant is solid).
- Cold-launch instant entry resolves in about a second with no pan.
- First-park notification rationale shows once, uncovered, and the ambient layer returns after it; the car pin is tappable after the session.
- Hint pill is once-only across relaunch.

## Kevin-device list (cannot be done on the simulator)
1. Outdoor / sunlight legibility of the highlight and the card (design A.5).
2. Feel verdict on the 2 m side-commit dead-band.
3. Real VoiceOver: adjustable curb-cycling element, retitled summary, label vs visible title.
4. Real GPS: puck/tip relationship on Report entry (finding #5), fix freshness, Find-me deferral.
5. Rotated / pitched map no-curb save and report coordinate vs reticle (AXe could not drive rotation here).
6. Notification deep link mid-session, background mid-pan, community pending card.
7. Reduce Motion, Pro Max budget, SE hardware check of the card after the #1/#2 fix.
