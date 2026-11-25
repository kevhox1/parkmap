# Handoff: WePark round 2, every screen

## Overview
The full screen-by-screen redesign of the WePark iPhone app (NYC street parking, SwiftUI + MapKit) in the "Stoop, straight" design system. 151 screen states across 18 groups (B1 to B18), plus three open questions answered as proposals (A1 to A3). It builds on the design system package (`design_handoff_wepark_design_system/`); read that README first for tokens and the three rules.

## About the design files
The `.dc.html` files are design references built in HTML. They show the intended look, wording and states. They are not production code. Recreate them in the existing SwiftUI codebase using its own patterns.

Open any `WePark Round 2 - *.dc.html` in a browser from this folder. They need the sibling `support.js` and the `WP*.dc.html` part files.

## Fidelity
High-fidelity for layout, colour, type, radii, borders, wording and which pieces are raised. Caveats:
- The map is a simplified grid standing in for MapKit. Match curb lines, markers and overlays; treat the base map colours as a target.
- No icons are drawn. Each screen's note names the SF Symbol (Rounded, Semibold) proposed for it. Confirm each name and its minimum iOS version in Xcode.
- The cat avatar is a placeholder circle labelled "cat glyph".
- The PNGs are about 1.1x (436 × 924 px for a 375 × 812 pt screen plus bezel). Use them to find a screen; use the HTML for exact values.

## The three rules (unchanged)
1. Facts are flat.
2. Raised (hard offset shadow) means it can be pressed or was earned.
3. Line style carries the answer: solid = park, broken = don't. Unsure is drawn as don't.

## Shared parts (`WP*.dc.html`)
Each is one reusable piece. Props are listed in the `data-props` attribute at the bottom of each file.
- `WPPhone` — 375 × 812 pt screen in a bezel. Not part of the app.
- `WPMap` — the stand-in map. Variants: live, more, less, sparse, detail (five line styles), blank, nodata. Can outline one selected curb.
- `WPGoalSheet` — the map's bottom sheet: toolbar (search, More, Locate), headline end time, three goal tiles, Start driving. Optional "Change" lever.
- `WPCurbSheet` — curb detail sheet with the verdict block. Kinds: park, soon, dont, meter, nodata, planpark, plandont.
- `WPDrive` — drive mode. Each side is park, dont, nodata or unsure; sizes change when both or neither side can be parked on.
- `WPMyCar` — the parked-car screen. Kinds: park, soon, dont, meter, nodata. Optional good-news banner and limit row.
- `WPPass` — the full-screen scaffold used by Spot Pass, the App Clip, onboarding and blocking errors.

## Parts added in round 2
- **Map toolbar:** search field (flex), More and Locate (48 circles). White, 1.5 line. Sits 12 above the sheet.
- **End-time lever (A1):** "Change" (2.5 line, 48 tall) beside the headline only while Overnight is chosen. Opens a row of hour chips, 6 to 10 AM, 52 tall. Map and headline update per tap.
- **Verdict block:** radius 24, padding 16/18. Over-line 15/500, time 36 to 44/700, sub-line 14/500. Park = #3CCF7A fill. Soon = #F2A23A fill. Don't = 3pt dashed #E39A90 outline, over-line in #B8322A. Metered = 3pt dotted #5B7CFA outline. No data = 2pt #A9A7B8 outline.
- **Full-screen scaffold:** cream ground; wordmark 20/600 and a 48 close pill at top 58; headline 32/600, body 17/400; rows with gap 10; primary button pinned to the bottom (taxi raised 72 tall for a commitment, ink 64 tall for navigation); optional text secondary 56 tall.
- **Choice chip:** white, 2pt line, radius 20, 56 to 64 tall, label 17 to 18/600. Chosen = taxi fill, 2.5 line, raise 4.
- **List card:** white, 1.5 line, radius 20, horizontal padding 18. Rows 56 minimum, label 17/600, hairline #E4E3EC between rows. Trailing chevron, switch, or value 15/400.
- **Switch:** 56 × 34, 2.5 line, knob 22. On = #3CCF7A, off = #E4E3EC.
- **Limit row:** 3pt dashed #E39A90 outline, radius 20, message 15/600, fix button (2.5 line, 48 tall) on the right. Goes directly above the feature it limits.
- **Coach card and ring:** card is white, 2.5 line, radius 24, with "n of 3", a 20/600 line, a 15/400 line, Skip and Next (ink, 48). The target gets a 4pt taxi ring with a 2.5pt ink outline. No scrim.
- **Trip frame and tag:** 4pt dashed #6A4CFF frame inset 5 from the screen edge; tag with 135° stripes #6A4CFF / #5A3DF0, white text, "TRIP PLAN · NOT LIVE" 12/600 tracked, dates 15/600. While it shows: no "you" dot, car token, goals, Start driving or Park here.
- **Stamp:** "SPOT PASSED", 2.5pt dashed ink outline, radius 16, 16/700 tracked, rotated -5°.
- **Hollow token:** 2.5pt dashed #A9A7B8 circle. Means "nothing here": pass ended, no parked car.
- **Karma sticker:** taxi, 2.5 line, raise 3, rotated 6°, "♥ +5 karma" 16/700.
- **Web URL bar:** only a stand-in for Safari's chrome in the web mocks.

## Decisions proposed in this round (confirm or change)
- **A1:** Overnight's end time is changed from the headline, not from a separate setting.
- **A2:** app icon = taxi token on a curb that turns from solid green to dashed coral, ink-violet field.
- **A3:** icon changes from your list: car token `car.fill`; swept `bubbles.and.sparkles.fill`; enforcement `ticket.fill`; metered `dollarsign.circle.fill`; pass your spot `hand.wave.fill`; no icons for left/right (always spelled out); offline `wifi.slash`.
- "About 10 min" replaces "~10 min" so VoiceOver reads it cleanly.
- The driver's auto heads-up is an opt-in switch, off by default.
- Loading and failed-load maps show no curb lines, so they can't be read as "no sign data".

## Things I assumed (please check)
- School-days rule: treated as in effect unless the app knows school is closed.
- Parking 101 rule wording, the FAQ questions, the report-a-pass reasons, and the `/get` page path are drafts.
- Offline assumes curb rules are cached on the phone.
- About: version and data sources are placeholders.
- Example times: map screens are Wed Nov 25, 10:11 PM; Spot Pass is scanned at 4:02 PM with a 4:45 PM leave time; trip planner is 2:11 PM.

## Screen index

### `WePark Round 2 - 1 Map.dc.html`
A1 Overnight lever, A2 app icon and logo, A3 icon map, B2 main map states

| Screen | PNG |
|---|---|
| A1.1 · Closed (Overnight selected) | `screenshots/a1-closed.png` |
| A1.2 · Changing | `screenshots/a1-changing.png` |
| A1.3 · Result after choosing 9 AM | `screenshots/a1-result.png` |
| B2.1 · A few hours selected | `screenshots/b2-hours.png` |
| B2.2 · For days selected, sparse | `screenshots/b2-days.png` |
| B2.3 · Show all sign details on | `screenshots/b2-detail.png` |
| B2.4 · Street cleaning suspended today | `screenshots/b2-asp.png` |
| B2.5 · No location permission | `screenshots/b2-noloc.png` |
| B2.6 · Outside coverage | `screenshots/b2-outside.png` |
| B2.7 · Loading curbs | `screenshots/b2-loading.png` |
| B2.8 · Offline | `screenshots/b2-offline.png` |
| B2.9 · AX5 (largest text) | `screenshots/b2-ax5.png` |
| A2 · App icon and logo (sheet) | `screenshots/a2-app-icon-and-logo.png` |

### `WePark Round 2 - 2 Search Curb Parking.dc.html`
B3 search, B4 curb detail, B6 parking

| Screen | PNG |
|---|---|
| B3.1 · Search peek (field tapped) | `screenshots/b3-peek.png` |
| B3.2 · Typing with suggestions | `screenshots/b3-typing.png` |
| B3.3 · Destination card | `screenshots/b3-dest.png` |
| B3.4 · Destination card, AX5 | `screenshots/b3-ax5.png` |
| B4.1 · Free for the window | `screenshots/b4-free.png` |
| B4.2 · Free now, changes soon (detail mode) | `screenshots/b4-soon.png` |
| B4.3 · No parking right now | `screenshots/b4-dont.png` |
| B4.4 · Metered now | `screenshots/b4-meter.png` |
| B4.5 · No sign data | `screenshots/b4-nodata.png` |
| B4.6 · Trip plan: free | `screenshots/b4-planfree.png` |
| B4.7 · Trip plan: not free | `screenshots/b4-plandont.png` |
| B4.8 · With a neighbor-reported restriction | `screenshots/b4-temp.png` |
| B4.9 · With a swept badge | `screenshots/b4-swept.png` |
| B4.10 · Live pins and block chatter (sheet pulled up) | `screenshots/b4-chatter.png` |
| B4.11 · Sign list open | `screenshots/b4-signs.png` |
| B4.12 · AX5 | `screenshots/b4-ax5.png` |
| B6.1 · Token picked up | `screenshots/b6-drag.png` |
| B6.2 · Snapped to a park curb | `screenshots/b6-snap-park.png` |
| B6.3 · Snapped to a don't curb | `screenshots/b6-snap-dont.png` |
| B6.4 · Placed, with address: confirm | `screenshots/b6-confirm.png` |
| B6.5 · Placed on a don't curb: warning | `screenshots/b6-confirm-dont.png` |
| B6.6 · Reminder priming (first park only) | `screenshots/b6-notify.png` |
| B6.7 · Parked-car marker on the map | `screenshots/b6-parked.png` |

### `WePark Round 2 - 3 Drive My Car.dc.html`
B5 drive mode, B7 My Car

| Screen | PNG |
|---|---|
| B5.1 · Drive start | `screenshots/b5-start.png` |
| B5.2 · Both sides parkable | `screenshots/b5-both.png` |
| B5.3 · Neither side | `screenshots/b5-neither.png` |
| B5.4 · No sign data on one side | `screenshots/b5-nodata.png` |
| B5.5 · Checking sides | `screenshots/b5-unsure.png` |
| B5.6 · Destination set | `screenshots/b5-dest.png` |
| B5.7 · Approaching destination | `screenshots/b5-near.png` |
| B5.8 · Arrival prompt | `screenshots/b5-arrive.png` |
| B5.9 · Voice off | `screenshots/b5-muted.png` |
| B5.10 · Report from drive, tap 2 | `screenshots/b5-report.png` |
| B5.11 · Report from drive, tap 3 | `screenshots/b5-report-side.png` |
| B5.12 · Report sent | `screenshots/b5-report-sent.png` |
| B5.13 · Park here confirm | `screenshots/b5-confirm.png` |
| B5.14 · Drive ended without parking | `screenshots/b5-ended.png` |
| B5.15 · AX5 drive card | `screenshots/b5-ax5.png` |
| B7.1 · Changes soon | `screenshots/b7-soon.png` |
| B7.2 · No parking now | `screenshots/b7-dont.png` |
| B7.3 · Metered now | `screenshots/b7-meter.png` |
| B7.4 · Street cleaning suspended tomorrow | `screenshots/b7-suspended.png` |
| B7.5 · No sign data | `screenshots/b7-nodata.png` |
| B7.6 · Reminders sheet | `screenshots/b7-remind.png` |
| B7.7 · I'm leaving sheet | `screenshots/b7-leaving.png` |
| B7.8 · See the signs, expanded | `screenshots/b7-signs.png` |
| B7.9 · After "I left" | `screenshots/b7-left.png` |
| B7.10 · AX5 version | `screenshots/b7-ax5.png` |

### `WePark Round 2 - 4a Community Seeker.dc.html`
B8 community reports and chatter, B9 Spot Pass seeker

| Screen | PNG |
|---|---|
| B8.1 · Report type picker | `screenshots/b8-type.png` |
| B8.2 · Mark the blocked part, a stretch | `screenshots/b8-mark.png` |
| B8.3 · Mark the blocked part, a pin | `screenshots/b8-pin.png` |
| B8.4 · Crew identity, first post only | `screenshots/b8-crew.png` |
| B8.5 · Posted, karma earned | `screenshots/b8-posted.png` |
| B8.6 · Map pins, one per report type | `screenshots/b8-pins.png` |
| B8.7 · A pin's detail | `screenshots/b8-detail.png` |
| B8.8 · Block chatter thread | `screenshots/b8-chatter.png` |
| B8.9 · Chatter compose | `screenshots/b8-compose.png` |
| B9.1 · Intro | `screenshots/b9-intro.png` |
| B9.2 · Create pass | `screenshots/b9-create.png` |
| B9.3 · QR badge, waiting | `screenshots/b9-qr.png` |
| B9.4 · Neighbor's on it | `screenshots/b9-armed.png` |
| B9.5 · Heads-up: leaving now | `screenshots/b9-headsup.png` |
| B9.6 · Thanks sent | `screenshots/b9-thanks.png` |
| B9.7 · Expired | `screenshots/b9-expired.png` |
| B9.8 · Driver isn't leaving after all | `screenshots/b9-cancelled.png` |
| B9.9 · Unavailable | `screenshots/b9-unavailable.png` |
| B9.10 · Karma | `screenshots/b9-karma.png` |

### `WePark Round 2 - 4b Driver Clip Lock.dc.html`
B10 Spot Pass driver, B11 App Clip, B12 Live Activity and Dynamic Island, B13 notifications

| Screen | PNG |
|---|---|
| B10.1 · Scanned pass, leave-time chips | `screenshots/b10-scanned.png` |
| B10.2 · Pick a time | `screenshots/b10-pick.png` |
| B10.3 · Armed, with the auto heads-up row | `screenshots/b10-armed.png` |
| B10.4 · Auto heads-up on | `screenshots/b10-auto.png` |
| B10.5 · Connect to your car guide | `screenshots/b10-car.png` |
| B10.6 · Leaving countdown | `screenshots/b10-countdown.png` |
| B10.7 · Finished, thanks received | `screenshots/b10-finished.png` |
| B10.8 · Pass unavailable | `screenshots/b10-ended.png` |
| B10.9 · Offline | `screenshots/b10-offline.png` |
| B10.10 · Spot Pass not live yet | `screenshots/b10-notlive.png` |
| B11.1 · App Clip card (system sheet) | `screenshots/b11-card.png` |
| B11.2 · First screen | `screenshots/b11-first.png` |
| B11.3 · Notification permission | `screenshots/b11-notif.png` |
| B11.4 · Pick a leave time | `screenshots/b11-time.png` |
| B11.5 · Armed | `screenshots/b11-armed.png` |
| B11.6 · Block info | `screenshots/b11-block.png` |
| B11.7 · Countdown | `screenshots/b11-countdown.png` |
| B11.8 · Finished | `screenshots/b11-finished.png` |
| B11.9 · Get the full app | `screenshots/b11-getapp.png` |
| B12.1 · Lock screen, armed countdown | `screenshots/b12-armed.png` |
| B12.2 · Lock screen, it's time | `screenshots/b12-time.png` |
| B12.3 · Lock screen, leaving sent | `screenshots/b12-sent.png` |
| B12.4 · Lock screen, thanks received | `screenshots/b12-thanks.png` |
| B12.5 · Lock screen, ended | `screenshots/b12-ended.png` |
| B12.6 · Dynamic Island: compact, minimal, expanded | `screenshots/b12-island.png` |
| B13 · Notifications (sheet of all 10) | `screenshots/b13-notifications.png` |

### `WePark Round 2 - 5a Onboarding Trip Edge.dc.html`
B1 first run, B14 Plan a Trip, B18 empty, error and edge states

| Screen | PNG |
|---|---|
| B1.1 · Story card 1: the two lines | `screenshots/b1-story1.png` |
| B1.2 · Story card 2: every free has an end | `screenshots/b1-story2.png` |
| B1.3 · Story card 3: the three goals | `screenshots/b1-story3.png` |
| B1.4 · Location priming | `screenshots/b1-location.png` |
| B1.5 · Notification priming | `screenshots/b1-notif.png` |
| B1.6 · Coach mark 1: goals | `screenshots/b1-coach1.png` |
| B1.7 · Coach mark 2: curb lines | `screenshots/b1-coach2.png` |
| B1.8 · Coach mark 3: Start driving | `screenshots/b1-coach3.png` |
| B1.9 · Arrived via Spot Pass: you helped | `screenshots/b1-helped.png` |
| B1.10 · Arrived via Spot Pass: you were helped | `screenshots/b1-washelped.png` |
| B14.1 · Entry point (More) | `screenshots/b14-entry.png` |
| B14.2 · Planner | `screenshots/b14-planner.png` |
| B14.3 · Validation errors | `screenshots/b14-errors.png` |
| B14.4 · Trip map | `screenshots/b14-map.png` |
| B14.5 · Curb verdict: free for the trip | `screenshots/b14-park.png` |
| B14.6 · Curb verdict: not for the whole trip | `screenshots/b14-dont.png` |
| B14.7 · Street-cleaning calendar not published | `screenshots/b14-nocal.png` |
| B14.8 · Back to live | `screenshots/b14-exit.png` |
| B14.9 · AX5 (largest text) | `screenshots/b14-ax5.png` |
| B18.1 · No location permission | `screenshots/b18-noloc.png` |
| B18.2 · Location only "While Using" | `screenshots/b18-whileusing.png` |
| B18.3 · Notifications off | `screenshots/b18-notifoff.png` |
| B18.4 · Offline | `screenshots/b18-offline.png` |
| B18.5 · Server down | `screenshots/b18-server.png` |
| B18.6 · No curbs loaded | `screenshots/b18-nocurbs.png` |
| B18.7 · Outside Manhattan | `screenshots/b18-outside.png` |
| B18.8 · Account or sign-in problem | `screenshots/b18-account.png` |
| B18.9 · First launch, no parked car | `screenshots/b18-nocar.png` |

### `WePark Round 2 - 5b More Settings Web.dc.html`
B15 More and Settings, B16 Parking 101, B17 web pages

| Screen | PNG |
|---|---|
| B15.1 · More sheet | `screenshots/b15-more.png` |
| B15.2 · Settings | `screenshots/b15-settings.png` |
| B15.3 · Reminder defaults | `screenshots/b15-reminders.png` |
| B15.4 · Delete account, confirmation | `screenshots/b15-delete.png` |
| B15.5 · Suggest a neighborhood | `screenshots/b15-suggest.png` |
| B15.6 · What the colors mean | `screenshots/b15-colors.png` |
| B15.7 · Help and FAQ | `screenshots/b15-help.png` |
| B15.8 · About | `screenshots/b15-about.png` |
| B16.1 · Top of the page | `screenshots/b16-1.png` |
| B16.2 · Middle | `screenshots/b16-2.png` |
| B16.3 · End of the page | `screenshots/b16-3.png` |
| B17.1 · /p · Waiting, leave-time chips | `screenshots/b17-waiting.png` |
| B17.2 · /p · Armed, keep this page open | `screenshots/b17-armed.png` |
| B17.3 · /p · Leaving sent | `screenshots/b17-sent.png` |
| B17.4 · /p · Finished | `screenshots/b17-finished.png` |
| B17.5 · Get WePark (TestFlight for now) | `screenshots/b17-get.png` |
| B17.6 · /p · Report a pass | `screenshots/b17-report.png` |
| B17.7 · /p · Unavailable or not live yet | `screenshots/b17-ended.png` |
| B17.8 · getwepark.com landing page | `screenshots/b17-landing.png` |

## Files
- `WePark Round 2 - *.dc.html` — the seven screen files.
- `WP*.dc.html` — shared parts.
- `screenshots/` — one PNG per screen state, named by its id in the HTML.
- `source/WePark-screens-round2.md` — the brief these screens answer.
- `support.js` — runtime the HTML files need.
