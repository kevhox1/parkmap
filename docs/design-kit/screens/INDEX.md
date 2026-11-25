# WePark iOS screen inventory

Neutral record of what exists in the app today, captured 2026-11-24 from `main` at `bc6467f0`
(Debug build, iOS 26.5 simulator). Screenshots are PNG, downscaled to max 1000 px tall.
No annotations; descriptions are factual only.

## How these were captured

- Devices: iPhone 17 (6.3") for everything, plus iPhone SE (3rd gen) for the main map, drive card and My Car (section 12).
- Location: simulated at E 2nd St & 2nd Ave, East Village (`xcrun simctl location`). Drive Mode shots use simulated movement (`simctl location start`).
- Builds (both local only, nothing committed):
  - **Flags ON build**: `driveModeDefaultEnabled`, `curbPinPlacementEnabled`, `addressAnchoredParkingEnabled`, `spotHandoffEnabled`, `spotHandoffAutoDetectEnabled`, `planTripEnabled`, `onboardingStoryEnabled` all set to `true`. `communityEnabled` is `true` on main; `regularsEnabled`, `accountDeletionEnabled`, `coverageRequestsEnabled` stay `false` (so those rows and screens do not appear).
  - **All flags OFF build** (unmodified main): the legacy / public experience. Filenames start `legacy-`.
- Spot Pass uses the DEBUG fake API: `-spotPassUseFakeAPI YES`, `-spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_-` (the full app and clip both accept it), `-spotPassFakeScenario <name>`, `-spotPassFakeLeaveSeconds <n>`, `-spotPassSeedCarryOver YES -spotPassSeedHelped 2 -spotPassSeedPending 1`.
- App Clip: `WeParkClip` scheme build, launched with `SIMCTL_CHILD__XCAppClipURL` plus the same debug args.
- Notification banners: `xcrun simctl push` with payloads shaped like `supabase/functions/_shared/handoff_push.ts` (`armed`, `departed`, `thanks`).
- Web fallback: Safari in the sim at `https://getwepark.com/p?fake=1`.
- Appearance: the in-app map renders with a dark map style in both system appearances; light and dark system appearance shots are in section 2.
- Interaction: AXe taps, `xcrun simctl ui` for appearance and AX5 (`accessibility-extra-extra-extra-large`).

## 1. Launch and first run

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 001-onboarding-page-1.png | Onboarding story card 1 of 3: 'Parking here is a game you play twice a week' | Fresh install, first launch | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 002-onboarding-page-2.png | Onboarding story card 2 of 3 | Onboarding > Continue | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 003-onboarding-page-3.png | Onboarding story card 3 of 3 | Onboarding > Continue | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 004-onboarding-location-priming-card.png | Location priming card over the goal-first map (before any permission), with default map position | Onboarding finished (Let's go) | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 005-perm-location-flagon.png | iOS location permission alert (flags-on build) | Priming card > Allow | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 006-coach-mark-1-goals.png | Coach mark 1 of 3 'Pick what you need.' highlighting the goal dock, with Skip | After location granted on first run | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 007-coach-mark-2.png | Coach mark 2 of 3 | Coach mark 1 > Got it | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 008-coach-mark-3.png | Coach mark 3 of 3 | Coach mark 2 > Got it | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 009-spotpass-welcome-carryover.png | Full-app Welcome for a user arriving from the App Clip: 'Welcome, neighbor.' helped-count and pending karma, Show me around, Skip | Fresh install with seeded clip carry-over context | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassSeedCarryOver YES -spotPassSeedHelped 2 -spotPassSeedPending 1; fresh install | iPhone 17 |

## 2. Main map, goals, search, More, Settings (flags on)

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 010-map-goal-overnight.png | Main map, Overnight goal selected (default): Start Driving, goal banner row with 'Until 7 AM' lever, three goal tiles, Search/More/Locate buttons | Finish first-run; default goal | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 011-map-goal-few-hours.png | Main map, A Few Hours goal selected: banner row and lever | Tap A Few Hours tile | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 012-map-goal-park-and-forget.png | Main map, Park & Forget goal selected: banner row and lever | Tap Park & Forget tile | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 013-map-goal-overnight-lever-menu.png | Overnight goal: morning-end lever menu open (hour choices) | Overnight goal > tap 'Until 7 AM' lever | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 014-more-sheet-medium.png | More sheet (medium height): Report, Spot Pass, How WePark works, What the colors mean | Tap the ... (More) button on the map | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 015-more-sheet-full.png | More sheet at full height | More sheet > swipe up | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 016-more-sheet-bottom.png | More sheet scrolled: Parking 101, Show all sign details toggle, Plan a trip, Settings rows | More sheet > scroll | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 017-colors-mean-sheet.png | What the colors mean sheet (curb colour and live-pin legend) | More > What the colors mean | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 018-more-sheet-sign-details-on.png | More sheet bottom with 'Show all sign details' toggle ON | More > Show all sign details | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 019-map-sign-details-palette.png | Main map with 'Show all sign details' on: full curb palette (amber metered, orange soon, gray) instead of green/red only | More > Show all sign details ON > Done | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 020-search-sheet-peek.png | Search sheet (initial): search field, Find a Spot, New to parking? link | Tap the magnifier button on the map | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 021-search-suggestions.png | Search sheet with typed query and Suggestions list | Search sheet > type 'Washington Square' | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 022-search-destination-card.png | Destination card after choosing a result: name, address, distance, Go button | Search > tap a suggestion | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 023-map-sign-details-dock.png | Main map with sign details on: dock shows Start Driving and 'Pick a parking goal' button | More > Show all sign details ON | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 024-search-destination-card-parking-summary.png | Destination card with 'Parking near here: mostly free' summary line and Go button | Search > Tompkins Square Park | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 025-settings-sheet.png | Settings sheet (flags-on build): Help, Notifications, Move-Your-Car reminders | More > Settings | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 026-map-appearance-light.png | Main map (goal dock, Overnight) with system appearance set to Light | xcrun simctl ui appearance light | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 027-map-appearance-dark.png | Main map (goal dock, Overnight) with system appearance set to Dark | xcrun simctl ui appearance dark | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 028-more-sheet-appearance-light.png | More sheet with system appearance Light | More sheet, appearance light | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |

## 3. Block / curb detail sheets (flags on)

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 029-block-sheet-metered.png | Block detail sheet: metered curb (flags-on, sign-details palette on) | Tap an amber curb segment | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 030-block-sheet-free.png | Block detail sheet: free curb | Tap a green curb segment | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 031-block-sheet-restricted.png | Block detail sheet: restricted curb ('No standing') | Tap a red curb segment | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 032-block-sheet-good-through.png | Block detail sheet: curb with 'Good through Mon 11/30' headline and one ASP Mon/Thu rule, block chatter empty, Park here and Report a problem | Tap a green curb (E 1st St north side) | driveModeDefault+curbPin+addressAnchored+planTrip+spotHandoff ON | iPhone 17 |

## 4. Drive Mode (flags on)

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 033-drive-start-background-note.png | Drive start: 'Keep WePark in Front' first-use alert over the drive map and card | Tap Start Driving (first time) | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 034-drive-card-standing.png | Drive card: street name, mute button, LEFT 'No parking' (red) and RIGHT 'Metered' (red); goal chip 'Overnight · Now → 7:00 AM tomorrow'; Report and Park here buttons | Start Driving, stationary at E Houston St / 2nd Ave | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 035-drive-card-both-green.png | Drive card with LEFT and RIGHT both green ('Free until…') | Drive Mode, simulated movement north on 2nd Ave (E 4th St) | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 036-drive-card-dash-side.png | Drive card with LEFT green and RIGHT '—' (no data side) | Drive Mode, simulated movement (E 5th St) | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 037-drive-card-muted.png | Drive card with callouts muted (speaker icon slashed) | Drive Mode > mute button | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 038-drive-report-sheet.png | Report sheet opened from Drive Mode ('Reporting on 2ND AVENUE') | Drive Mode > Report button | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 039-drive-park-here-checklist.png | 'Check before you park' checklist sheet opened from Drive Mode Park here (checkbox rows, I checked — Park here, Cancel) | Drive Mode > Park here | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 040-drive-card-destination-distance.png | Drive card with a destination set: distance readout ('0.4 mi'), both sides green | Search > destination > Go; simulated movement | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 041-drive-approaching-destination.png | Drive card with 'Approaching destination' strip, destination pin on map, distance 0.0 mi | Drive Mode with destination; simulated arrival at Tompkins Square Park | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 042-drive-ended-map.png | Map after End Drive Mode: goal dock restored, map stays near last location | Drive Mode > End | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 043-drive-park-confirm-sheet.png | Park my car confirm sheet from Drive Mode: street/side, 'Wrong street? Nearby blocks' list, rule headline, reminder toggle, Cancel / Park here | Drive Mode > Park here > I checked — Park here | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |

## 5. Parking: placement, Park here, My Car (flags on)

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 044-curbpin-placement-restricted.png | Curb-pin placement mode: fixed pin snapped to a no-standing curb, first-use hint pill, address line, Park here button | Block sheet > Park here | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 045-curbpin-placement-after-drag.png | Curb-pin placement mode after dragging the map: snap card updates | Placement mode > drag map | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 046-curbpin-placement-free.png | Curb-pin placement mode snapped to a free curb: green verdict card | Placement mode > drag map to a green curb | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 047-parkhere-notif-priming.png | Reminder pre-permission sheet shown immediately after Park here in placement mode | Placement mode > Park here (first time) | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 048-map-parked-car-marker.png | Main map with parked-car marker on the curb (goal dock still visible) | After Park here | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 049-mycar-sheet-medium.png | My Car sheet (current) at medium height after curb-pin Park here, flags on | Tap the parked-car marker | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 050-mycar-sheet-full.png | My Car sheet (current) at full height: reminder chips, rules, crew hand-off card, I left button | Parked-car marker > swipe up | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 051-map-after-i-left-flagon.png | Main map after I left (parked-car marker cleared), goal dock restored | My Car sheet > I left | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 052-mycar-sheet-address-line.png | My Car sheet (current) with address line 'In front of 18 2nd Ave', 'No standing zone (active now)' warning, 'Parked 1m ago' | Curb-pin Park here on a no-standing curb, tap marker | driveModeDefault+curbPin+addressAnchored+spotHandoff+planTrip ON; default text size | iPhone 17 |

## 6. Community / report (flags on)

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 053-report-sheet-from-block.png | Report sheet 'What's happening?' opened from the block sheet's 'Report a problem on this block' | Block sheet > Report a problem on this block | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |

## 7a. Spot Pass seeker

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 054-spotpass-seeker-intro.png | Spot Pass seeker intro: 'Pass the spot.' three steps, Show my first name toggle, Create my Spot Pass | More > Spot Pass | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES | iPhone 17 |
| 055-spotpass-seeker-waiting-qr.png | Spot Pass seeker: QR badge shown, waiting for a neighbor to scan | Spot Pass intro > Create my Spot Pass | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES | iPhone 17 |
| 056-spotpass-seeker-neighbor-on-it.png | Spot Pass seeker: 'A neighbor's on it. Leaving in about 30 min.' (a neighbor scanned and armed) | Create a pass; fake API arms it after ~10 s | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES | iPhone 17 |
| 057-spotpass-seeker-heads-up.png | Spot Pass seeker heads-up: 'Spot opening up. Your neighbor is pulling out now.' with Got it, thanks! / Didn't work out | Created pass; fake API departs ~25 s after arming | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES | iPhone 17 |
| 058-spotpass-seeker-thanks.png | Spot Pass seeker: state after tapping Got it, thanks! | Heads-up > Got it, thanks! | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES | iPhone 17 |

## 7b. Spot Pass driver (full app)

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 059-spotpass-driver-scanned-chips.png | Spot Pass driver (full app): scanned pass 'Bodega Cat is waiting for your spot', leave-time chips Now/10 min/30 min/1 hr/Pick a time, primary and secondary buttons | Launch with injected pass link | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- | iPhone 17 |
| 060-spotpass-driver-pick-a-time.png | Spot Pass driver: 'Pick a time' picker expanded | Driver screen > Pick a time | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- | iPhone 17 |
| 061-spotpass-driver-custom-time-selected.png | Spot Pass driver with a custom time chip selected | Pick a time > Set time | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 120 | iPhone 17 |
| 062-spotpass-driver-armed.png | Spot Pass driver armed: 'You're on, neighbor.' reminder time, lock-screen note, I'm pulling out, auto heads-up row, Not leaving after all | Driver screen > Tell … when I leave | spotHandoffEnabled+spotHandoffAutoDetectEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 120 | iPhone 17 |
| 063-spotpass-driver-car-auto-ping-guide.png | Spot Pass driver: 'Auto heads-up from your car' Shortcuts setup guide (4 steps, Open Shortcuts) | Armed driver screen > auto heads-up row | spotHandoffEnabled+spotHandoffAutoDetectEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 120 | iPhone 17 |
| 064-spotpass-driver-leaving-countdown.png | Spot Pass driver: 'Leaving in' countdown screen with I'm pulling out, 5 more min, Not leaving | Armed driver screen > I'm pulling out (before leave time) | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 120 | iPhone 17 |
| 065-spotpass-driver-finished.png | Spot Pass driver finished: 'You just passed a spot.' SPOT PASSED stamp, +5 karma pending, Done | Leaving countdown > I'm pulling out | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 120 | iPhone 17 |
| 066-spotpass-driver-scenario-unavailable.png | Spot Pass driver error/edge state: fake scenario 'unavailable' | Launch with injected link and -spotPassFakeScenario unavailable | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeScenario unavailable | iPhone 17 |
| 067-spotpass-driver-scenario-offline.png | Spot Pass driver error/edge state: fake scenario 'offline' | Launch with injected link and -spotPassFakeScenario offline | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeScenario offline | iPhone 17 |
| 068-spotpass-driver-scenario-disabled.png | Spot Pass driver error/edge state: fake scenario 'disabled' | Launch with injected link and -spotPassFakeScenario disabled | spotHandoffEnabled ON (+ all flags on); launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeScenario disabled | iPhone 17 |
| 069-spotpass-driver-notification-permission.png | iOS notification permission alert over the Spot Pass driver screen (button shows progress, 'WePark will ask to remind you at your leave time') | Driver screen > Tell … when I leave (notifications not yet decided) | spotHandoffEnabled ON; launch -spotPassUseFakeAPI YES -spotPassFakeLeaveSeconds 90 -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_-; fresh install | iPhone 17 |

## 7c. App Clip

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 070-clip-first-screen.png | App Clip first screen after invocation: 'Bodega Cat is waiting for your spot.' with leave-time chips (the system App Clip card itself is not simulable) | Install WeParkClip.app, launch with injected invocation URL | WeParkClip scheme build; SIMCTL_CHILD__XCAppClipURL + -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 90 | iPhone 17 |
| 071-clip-arm-notification-permission.png | App Clip: arming in progress with iOS notification permission alert | Clip first screen > Tell … when I leave | WeParkClip scheme build; SIMCTL_CHILD__XCAppClipURL + -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 90 | iPhone 17 |
| 072-clip-armed.png | App Clip armed state | Clip > arm (notifications allowed) | WeParkClip scheme build; SIMCTL_CHILD__XCAppClipURL + -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 90 | iPhone 17 |
| 073-clip-armed-block-info.png | App Clip armed state with 'This block' street-cleaning info card expanded (fake location) | Clip armed > Show me this block | WeParkClip scheme build; SIMCTL_CHILD__XCAppClipURL + -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 90 | iPhone 17 |
| 074-clip-leaving-countdown.png | App Clip: Leaving in countdown with I am pulling out, 5 more min, Not leaving | Clip armed > I am pulling out (before leave time) | WeParkClip scheme build; SIMCTL_CHILD__XCAppClipURL + -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 90 | iPhone 17 |
| 075-clip-finished.png | App Clip finished state after I'm pulling out | Clip leaving countdown > I'm pulling out | WeParkClip scheme build; SIMCTL_CHILD__XCAppClipURL + -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- -spotPassFakeLeaveSeconds 90 | iPhone 17 |

## 7d. Notifications / lock screen

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 076-notif-banner-armed.png | Notification banner on the home screen: kind 'armed' | simctl push with the armed payload (handoff_push.ts shape), app backgrounded | spotHandoffEnabled ON (notifications allowed); xcrun simctl push with payload shaped like handoff_push.ts | iPhone 17 |
| 077-notif-banner-departed.png | Notification banner on the home screen: kind 'departed' | simctl push with the departed payload (handoff_push.ts shape), app backgrounded | spotHandoffEnabled ON (notifications allowed); xcrun simctl push with payload shaped like handoff_push.ts | iPhone 17 |
| 078-notif-banner-thanks.png | Notification banner on the home screen: kind 'thanks' | simctl push with the thanks payload (handoff_push.ts shape), app backgrounded | spotHandoffEnabled ON (notifications allowed); xcrun simctl push with payload shaped like handoff_push.ts | iPhone 17 |
| 079-notif-lock-screen.png | Lock screen with Spot Pass notifications stacked (departed, armed) | Lock the sim, simctl push two payloads | spotHandoffEnabled ON (notifications allowed); xcrun simctl push, device locked | iPhone 17 |

## 8. Plan a Trip

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 080-plan-trip-planner-sheet.png | Plan a trip planner sheet: quick picks, Arrive/Leave pickers, 'Show where I can park' | More > Plan a trip | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 081-plan-trip-planner-quickpick-applied.png | Planner sheet after tapping 'Tomorrow' quick pick (Arrive/Leave filled) | Planner > Tomorrow quick pick | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 082-plan-trip-map-banner.png | Map in TRIP PLAN mode: TRIP PLAN banner with window, 'not live' note, Edit and Exit trip plan buttons; dock replaced | Planner > Show where I can park | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 083-plan-trip-curb-verdict-free.png | Trip-plan curb verdict sheet: free for the whole trip (TRIP PLAN · not live label) | Trip plan active > tap a green curb | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |
| 084-plan-trip-curb-verdict-restricted.png | Trip-plan curb verdict sheet on a restricted curb | Trip plan active > tap a red curb | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone 17 |

## 9. Accessibility (AX5)

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 085-ax5-map-dock.png | Main map goal dock at Accessibility XXXL (AX5) text size | xcrun simctl ui content_size accessibility-extra-extra-extra-large | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON; content size AX5 | iPhone 17 |
| 086-ax5-drive-card.png | Drive card and drive buttons at AX5 text size | Start Driving with AX5 content size | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON; content size AX5 | iPhone 17 |
| 087-ax5-mycar-sheet.png | My Car sheet at AX5 text size (initial detent) | Park via curb-pin, set content size AX5 live, tap parked-car marker | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON; content size AX5 | iPhone 17 |
| 088-ax5-mycar-sheet-full.png | My Car sheet at AX5 text size, expanded | My Car sheet > swipe up, AX5 | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON; content size AX5 | iPhone 17 |
| 089-ax5-spotpass-driver-armed.png | Spot Pass driver armed state at AX5 text size (top) | Launch with injected pass link while a previously armed fake pass persists, AX5 | spotHandoffEnabled ON; content size AX5; launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- | iPhone 17 |
| 090-ax5-spotpass-driver-armed-scrolled.png | Spot Pass driver armed state at AX5 scrolled (lock-screen note, I am pulling out, auto heads-up row) | Armed driver screen AX5 > scroll | spotHandoffEnabled ON; content size AX5; launch -spotPassUseFakeAPI YES -spotPassClipURL https://getwepark.com/p#t=AbCdEfGhIjKlMnOpQrSt_- | iPhone 17 |

## 10. Web fallback page

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 091-web-fallback-waiting-chips.png | Web fallback page /p?fake=1: 'Bodega Cat is waiting for your spot' leave-time chips (~10 min preselected), Pick a time | Open https://getwepark.com/p?fake=1 in Safari | Safari, https://getwepark.com/p?fake=1 (no app flags involved) | iPhone 17 |
| 092-web-fallback-scrolled.png | Web fallback page scrolled: primary button and 'Get the free WePark app' card | Scroll the fallback page | Safari, https://getwepark.com/p?fake=1 (no app flags involved) | iPhone 17 |
| 093-web-fallback-pick-a-time.png | Web fallback page: 'Pick a time' control opened | Fallback page > Pick a time | Safari, https://getwepark.com/p?fake=1 (no app flags involved) | iPhone 17 |
| 094-web-fallback-report-pass.png | Web fallback 'Report this pass' reason list | Fallback page > Report this pass | Safari, https://getwepark.com/p?fake=1 (no app flags involved) | iPhone 17 |
| 095-web-fallback-custom-time-selected.png | Web fallback page with a picked time (11:00 PM) selected | Fallback page > Pick a time > choose a slot | Safari, https://getwepark.com/p?fake=1 (no app flags involved) | iPhone 17 |
| 096-web-fallback-armed.png | Web fallback page armed state after Tell Bodega Cat when I leave | Fallback page > Tell Bodega Cat when I leave | Safari, https://getwepark.com/p?fake=1 (no app flags involved) | iPhone 17 |
| 097-web-fallback-finished.png | Web fallback page after I'm leaving now (finished) | Armed page > I'm leaving now | Safari, https://getwepark.com/p?fake=1 (no app flags involved) | iPhone 17 |

## 11. Legacy / all flags OFF

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 098-legacy-perm-location.png | iOS location permission alert (shown over the map) | Fresh install, tap the locate (arrow) button on the map | all OFF (public build) | iPhone 17 |
| 099-legacy-map-light-first-launch.png | Main map, first launch after granting location, light appearance | Fresh install, grant location While Using, sim location E 2nd St & 2nd Ave | all OFF (public build) | iPhone 17 |
| 100-legacy-map-browse.png | Main map zoomed to block level with curb colour lines, ASP banner, Report pill, Park Until and recenter buttons, search dock | Grant location, tap recenter; sim location E 2nd St & 2nd Ave | all OFF (public build) | iPhone 17 |
| 101-legacy-block-sheet-metered.png | Block detail sheet: metered curb with rule rows and empty Block Chatter section, Park here button | Tap a yellow-curb block near 2nd Ave & E 2nd St | all OFF (public build) | iPhone 17 |
| 102-legacy-park-confirm.png | Park my car confirm sheet (street, side, rule summary, reminder toggle, Cancel / Park here) | Block sheet > Park here | all OFF (public build) | iPhone 17 |
| 103-legacy-notif-priming.png | Reminder pre-permission sheet 'Stay ahead of street cleaning' | Confirm Park here the first time (before notifications are authorised) | all OFF (public build) | iPhone 17 |
| 104-legacy-perm-notifications.png | iOS notification permission alert | Priming sheet > Enable Reminders | all OFF (public build) | iPhone 17 |
| 105-legacy-map-parked-car.png | Main map with parked-car marker and Recenter-on-car button | After confirming Park here | all OFF (public build) | iPhone 17 |
| 106-legacy-mycar-sheet-top.png | My Car sheet (current): street, rule headline, parked time, free-until line, reminder toggle and lead-time chips, Rules row, crew hand-off card | Tap the parked-car marker | all OFF (public build) | iPhone 17 |
| 107-legacy-mycar-sheet-full.png | My Car sheet at full height: reminder chips, Rules row, crew hand-off card with minute chips, I left button | Parked car marker > swipe sheet up | all OFF (public build) | iPhone 17 |
| 108-legacy-mycar-rules-expanded.png | My Car sheet with Rules (4) disclosure expanded | My Car sheet > tap Rules | all OFF (public build) | iPhone 17 |
| 109-legacy-crew-identity-sheet.png | Say hi to the crew: first-report identity sheet (emoji avatars, handle field, Join the board & post, Post anonymously) | My Car sheet > Leaving in 10 min tell the crew (first time) | all OFF (public build) | iPhone 17 |
| 110-legacy-map-after-i-left.png | Main map after tapping I left: parked-car marker and recenter-on-car button removed | My Car sheet > I left clear pin | all OFF (public build) | iPhone 17 |
| 111-legacy-park-until-sheet.png | Parking until when? sheet: quick picks and custom departure time | Tap the clock (Park Until) button on the map | all OFF (public build) | iPhone 17 |
| 112-legacy-park-until-selected.png | Parking until when? sheet with 2 hr selected and Confirm enabled | Park Until sheet > 2 hr | all OFF (public build) | iPhone 17 |
| 113-legacy-map-park-until-active.png | Map with Park Until filter active: toast 'Showing blocks free until…', green clock button, Until chip on dock | Park Until sheet > Confirm | all OFF (public build) | iPhone 17 |
| 114-legacy-settings-top.png | Settings sheet (medium height): Help, Notifications, Move-Your-Car reminders | Dock gear icon / Open settings | all OFF (public build) | iPhone 17 |
| 115-legacy-settings-bottom.png | Settings sheet scrolled to bottom: reminder lead times and Version row | Settings sheet > scroll down | all OFF (public build) | iPhone 17 |
| 116-legacy-parking-101.png | Parking 101 guide page (opened from Settings > Help) | Settings > Parking 101 | all OFF (public build) | iPhone 17 |
| 117-legacy-help-faq.png | Help & FAQ page | Settings > Help & FAQ | all OFF (public build) | iPhone 17 |
| 118-legacy-map-key.png | Map key sheet: curb colour legend and live-pin legend | Tap the ? (Map key) button on the map | all OFF (public build) | iPhone 17 |
| 119-legacy-search-suggestions.png | Browse sheet expanded with search field filled and destination Suggestions list above Find a Spot and zone chatter | Tap the search dock, type 'Washington Square' | all OFF (public build) | iPhone 17 |
| 120-legacy-search-destination-card.png | Destination card for chosen result: name, address, distance, Go button, then zone chatter | Search > tap a suggestion | all OFF (public build) | iPhone 17 |
| 121-legacy-drive-background-note.png | Drive Mode start with 'Keep WePark in Front' first-use alert over the 3D drive map | Destination card > Go (first time) | all OFF (public build) | iPhone 17 |
| 122-legacy-drive-mode-moving.png | Drive Mode (legacy) while moving: End button, Report and Park here buttons, drive card strip, mute button | Go to a destination with simulated movement along 2nd Ave | all OFF (public build) | iPhone 17 |
| 123-legacy-drive-muted.png | Drive Mode with callouts muted (speaker icon changed) | Drive Mode > mute button | all OFF (public build) | iPhone 17 |
| 124-legacy-map-after-drive-end.png | Main map after End Drive Mode (browse state restored) | Drive Mode > End | all OFF (public build) | iPhone 17 |
| 125-legacy-block-sheet-free.png | Block detail sheet: free curb ('Free until…' headline, rule rows, empty chatter, Park here) | Tap a green curb segment | all OFF (public build) | iPhone 17 |
| 126-legacy-block-sheet-restricted.png | Block detail sheet: restricted curb ('No parking' headline) | Tap a red curb segment | all OFF (public build) | iPhone 17 |
| 127-legacy-report-sheet.png | Report sheet 'What's happening?' (medium height): Enforcement active, Sweeper passed cards, Report button disabled | Tap Report pill on the map | all OFF (public build) | iPhone 17 |
| 128-legacy-report-sheet-selected.png | Report sheet at full height with Enforcement active selected, all four report types visible | Report sheet > swipe up > tap Enforcement active | all OFF (public build) | iPhone 17 |

## 12. iPhone SE (3rd gen)

| filename | screen / state | how to reach it | flags | device |
|---|---|---|---|---|
| 129-se-onboarding-page-1.png | Onboarding story card 1 of 3 on iPhone SE (3rd gen) | Fresh install, first launch | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone SE (3rd gen) |
| 130-se-coach-mark-1.png | Coach mark 1 'Pick what you need.' on iPhone SE | First run after onboarding Skip | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone SE (3rd gen) |
| 131-se-map-goal-overnight.png | Main map, Overnight goal, on iPhone SE (3rd gen) | Default goal on first run | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone SE (3rd gen) |
| 132-se-map-goal-few-hours.png | Main map, A Few Hours goal, on iPhone SE | Tap A Few Hours tile | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone SE (3rd gen) |
| 133-se-drive-card.png | Drive card and buttons on iPhone SE | Start Driving, stationary at E Houston St / 2nd Ave | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone SE (3rd gen) |
| 134-se-drive-park-confirm-sheet.png | Park my car confirm sheet from Drive Mode on iPhone SE (action buttons partly below the fold) | Drive Mode > Park here > I checked — Park here | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone SE (3rd gen) |
| 135-se-mycar-sheet.png | My Car sheet (current) on iPhone SE (initial detent) | Park from Drive Mode, tap parked-car marker | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone SE (3rd gen) |
| 136-se-mycar-sheet-full.png | My Car sheet on iPhone SE expanded | My Car sheet > swipe up | driveModeDefault+onboardingStory+planTrip+curbPin+addressAnchored+spotHandoff+autoDetect ON | iPhone SE (3rd gen) |
## Not captured, and why

- **Live Activity / lock-screen countdown**: with the fake API the driver screen reports "Lock-screen countdown is off" even though Live Activities are enabled for the app in the simulator's Settings, and no Live Activity appeared on the locked screen. Only the lock screen with notification banners is captured (section 7d).
- **System App Clip card** (the Apple-rendered invocation card): not simulable. Section 7c starts at the clip's own first screen.
- **Community content with real data**: reporting submit, the crew "leaving soon" pin on the map, and block chatter with messages. These write to the production backend, so no reports, pins or chatter messages were posted. Captured instead: the report type sheet (flows from the Report pill, the block sheet and Drive Mode), the crew identity sheet (legacy, section 11) and the empty chatter state in block sheets. A curb with existing community pins/chatter was not found near the capture point.
- **Real Spot Pass backend states** (live peek/claim): only fake-API states are shown. `slowPeek`, `claimOffline`, `noID`, `departFails` scenarios were not captured; `unavailable`, `offline`, `disabled` were.
- **Spot Pass driver "armed" shots in AX5**: the AX5 driver screen could only be reached in its armed state (an armed fake pass persisted across launches), so section 9 shows armed, not the waiting/chips state, at AX5.
- **Park Until filter and curb-pin placement variants**: the Park Until sheet only appears in the legacy (flags off) shots; the flags-on map has no Park Until button. Curb-pin placement was captured entering from the block sheet's Park here (not from a long-press or the Report pill).
- **Settings rows hidden behind dark-shipped flags** (Delete account, Suggest a neighborhood, Regulars): off in main, so not shown.
- **App Clip Welcome in the full app** (`spotpass-welcome-carryover`) required a fresh install; the Skip/finish path leads to the coach marks (section 1).
- **Light vs dark system appearance for the legacy pass** was not repeated; legacy shots were taken in light appearance.
- **Drive "—" side** was reached once (E 5th St, right side) via simulated movement; the destination arrival state is "Approaching destination" with distance 0.0 mi (no separate arrived screen was observed).
