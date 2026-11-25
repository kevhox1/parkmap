# WePark: remaining screens to design (round 2)

You designed **WePark design system v0.1, "Stoop, straight"** (option 2a). It covers the rules, tokens, parts, and three reference screens: the main map sheet, the drive card, and My Car. Engineering is now building that foundation in SwiftUI.

This round: **design every remaining screen and state in that same system.** Use its rules, tokens and parts. Where a screen needs a new part, add it to the system and say so.

Context you already have (re-attached in the design kit): `BRIEF.md` (hard product rules), `FLOWS.md`, and `screens/` (the current app; for context only, not a reference to follow).

**Global requirements for every screen below:**
- Canvas 375 × 812 pt. Also show **one AX5 (largest Dynamic Type) version** of each screen that carries a verdict, time or action. Verdicts and times must never truncate.
- **Light by default.** Drive mode and system-dark use the dark palette. Show dark versions where noted.
- **Wording rules from v0.1:** facts plain with end times; actions are verbs; neighbor moments may be warm; no emoji or exclamation marks in facts; always "Left side" / "Right side".
- **Never show a spot that isn't a spot.** Unsure is drawn as don't.
- **Trip plan (not live)** surfaces always carry "Trip plan · not live" and hide live actions (Park here, Report, Spot Pass).
- Icons: SF Symbols, Rounded, Semibold. Please name the exact symbol for each icon you use (see the icon list at the end).
- **Deliverable:** HTML references like round 1, one section per group, with every state labeled. Add any new tokens or parts to the system file.

---

## A. Open design questions (please propose an answer)

### A1. Overnight end-time lever
Overnight means **from now until the next morning**. The user can choose the morning end: 6, 7, 8, 9 or 10 AM, default 7. A later end can only remove green, never add it. Today a small menu ("Until 7 AM ▾") sits on the goal banner.
- **Need:** where and how this lives in the 2a map sheet. The headline already says "Green curbs are free from now until 7 AM tomorrow" and the goal tiles are below it. It must be quick to change, clearly tied to Overnight, and not clutter the sheet when another goal is selected.
- **Show:** the closed state, the changing state, and the result after changing.

### A2. App icon and logo
No logo exists yet. The name "WePark" is set in Fredoka 600 today.
- **Need:** an app icon (1024 × 1024, plus how it reads at 60 pt and on a light/dark/tinted home screen) and a wordmark/logo lockup for the App Store, the App Clip card, the web page and onboarding.

### A3. Icon map
Confirm or replace the proposed SF Symbol for each feature (list at the end).

---

## B. Screens to design

Each entry gives the **job** (what it must achieve), the **states** to draw, the **content** it shows, the **actions**, and the current screenshots for reference (in `screens/`).

### B1. First run / onboarding
- **Job:** in seconds, make a NYC driver believe this will save them tickets and time, then get location and notification permission without friction.
- **States:**
  - 3 story cards
  - location priming (before the iOS prompt)
  - notification priming
  - 3 coach marks: goals, the map/curb colors, Start driving
  - the variant for someone who arrived via Spot Pass (carry-over welcome: "you just helped / were helped by a neighbor")
- **Content:**
  - what green and coral curbs mean
  - that every "free" has an end time
  - the three goals
- **Actions:** Continue, Allow, Not now, Skip.
- **Rules:** the coral "don't" and green "park" line styles must be taught here.
- **Screens:** 001–009, 129–130.

### B2. Main map: the rest of the sheet and map states
- **Job:** at a glance, show where I can leave my car for the window I care about.
- **States** (the 2a map is the base):
  - **A Few Hours** selected ("until 8:15 PM")
  - **For days / Park & Forget** selected (shows which day it reaches, e.g. "until Wed 12/2", plus a "only a few blocks nearby are clear for a full week" message when sparse)
  - **Show all sign details** ON (five-state curb legend visible)
  - **ASP suspended today** (holiday/snow: "Street cleaning suspended today")
  - **No location permission**
  - **Outside coverage** (Brooklyn/Queens: "WePark covers Manhattan today")
  - **Loading curbs**
  - **Offline**
- **Content:**
  - window end time and duration from now
  - the info chip (e.g. "Street cleaning in effect today")
  - the karma chip
  - the car token with its "Drag to a curb to park" hint
- **Actions:** goal tiles, Start driving, search, More, locate me, drag the car token.
- **Screens:** 010–013, 019, 023, 026–027, 099–100.

### B3. Search
- **Job:** find a destination and see parking near it before driving.
- **States:**
  - search peek
  - typing with suggestions
  - destination card (address, distance, a parking summary for the selected window like "Free curbs within 2 blocks: 6", Drive here)
- **Actions:** search, pick a result, Drive here, close.
- **Screens:** 020–022, 024, 119–120.

### B4. Curb / block detail sheet (tap any curb)
- **Job:** tell me unambiguously whether I can park on this exact curb, until when, and why (the real signs).
- **States**, each using the v0.1 verdict blocks:
  - free for the window
  - free now but changes soon (detail mode)
  - no parking right now
  - metered now
  - no sign data
  - trip-plan verdict ("Free for your whole trip" / "Not free: street cleaning Sat 11 AM–12:30 PM")
  - with a live **temporary restriction** reported by neighbors (e.g. "Blocked for filming, reported 20 min ago")
  - with a **swept** badge (street cleaning done)
  - with **live pins** and **block chatter** (short messages from neighbors)
- **Content:**
  - street, side, cross streets ("E 1st St · North side · 1st–2nd Ave")
  - verdict and end time
  - the next restriction in plain words
  - the sign list (full text, deduped)
- **Actions:** Park here (the one taxi button), Report, See the signs, chatter compose.
- **Screens:** 029–032, 083–084, 101, 125–126.

### B5. Drive mode: everything beyond the 2a reference
- **Job:** tell me in one glance which side I can park on, without taking my attention off the road.
- **States:**
  - Drive start (with the background-location note)
  - both sides parkable (both large and green)
  - neither side
  - **no data on one side**
  - **unsure/changing direction** (sides being determined)
  - destination set: distance to destination
  - **approaching destination**
  - **arrival prompt** ("You've arrived. Park here?")
  - voice muted vs on
  - **Report from drive** (big targets, three taps max)
  - **Park here confirm** from drive
  - **drive ended**
  - the AX5 drive card
- **Rules:**
  - Left-side info hugs the left edge and right-side info hugs the right edge.
  - The parkable side is larger.
  - Voice says the same words as the bubbles.
  - Targets are 72–80.
- **Screens:** 033–043, 086, 121–124, 133–134.

### B6. Parking a car
- **Job:** mark exactly where I parked in a few seconds, at the right curb.
- **States:**
  - car token picked up (dragging)
  - snapped to a **park** curb
  - snapped to a **don't** curb (a warning: you're about to park where you can't)
  - placed with the address ("In front of 50 E 1st St")
  - confirm
  - notification priming (to get reminders)
  - parked-car marker on the map
- **Rules:** the token snaps to the nearest curb and drops with one bounce. Once parked, the marker is flat.
- **Screens:** 044–048, 102–105.

### B7. My Car: states beyond the 2a reference
- **States:**
  - free for days (the 2a reference)
  - **changes soon** (orange: "Free until 7 AM, 45 min left")
  - **no parking now** (move it)
  - **metered now** ("Meter until 7 PM")
  - **street cleaning suspended tomorrow**
  - **no sign data**
  - the **reminders** sheet (multi-select lead times: 15 min / 30 min / 1 hr / 2 hr, plus a separate "the night before")
  - the **I'm leaving** sheet (Tell neighbors with 5/10/15/20 min, Pass with Spot Pass, Just clear my car)
  - **See the signs** expanded
  - after "I left"
  - the AX5 version
- **"Walk there"** opens Apple Maps walking directions (owner decision).
- **Screens:** 049–052, 087–088, 106–108, 135–136.

### B8. Community: report, neighbors, chatter
- **Job:** make it quick and rewarding to tell neighbors what's happening on a block, and trustworthy to read.
- **States:**
  - Report type picker:
    - street cleaning done (swept)
    - enforcement / ticketing active
    - temporary no parking
    - blocked for filming
    - blocked for construction
    - open spot
    - leaving soon
  - **marking the blocked part of a block** (owner request: drop a pin, or drag along the curb to mark the stretch)
  - confirm/posted
  - crew identity setup (first post: a display name)
  - map pins for each report type (with expiry)
  - a pin's detail
  - block chatter thread and compose
  - karma earned for a report
- **Screens:** 038, 053, 109, 127–128.

### B9. Spot Pass: seeker (wants a spot)
- **Job:** make asking a stranger for their spot feel easy, safe and kind.
- **States:**
  - intro (what it is, privacy: "They won't see who you are or where you are")
  - create pass (option to show your first name)
  - **QR badge** (big, scannable through a car window; shows alias + glyph, e.g. "Bodega Cat")
  - waiting
  - **neighbor's on it** (armed: "Leaving around 4:15 PM")
  - **heads-up: leaving now**
  - thanks sent
  - expired / cancelled / unavailable
  - karma
- **Screens:** 054–058.

### B10. Spot Pass: driver (full app)
- **Job:** let a driver agree in seconds and tap one button when they leave.
- **States:**
  - scanned pass ("Bodega Cat is waiting for your spot")
  - leave-time chips: Now, ~10 min, ~30 min, ~1 hour, **Pick a time** (clock times every 15 min, up to 4 h ahead)
  - armed
  - **auto heads-up** opt-in row (sends automatically when the car starts driving)
  - "connect to your car" shortcut guide
  - leaving countdown
  - finished / thanks received
  - unavailable / offline / Spot Pass not live yet
- **Screens:** 059–069, 089–090.

### B11. App Clip (no install, opened by scanning the QR)
- **Job:** a stranger with no app agrees in seconds, then taps one button when leaving, even on a locked phone. This is often the **first impression of WePark**.
- **States:**
  - the **App Clip card** (the system sheet: a header image at 1800 × 1200 / 3:2, a title of max 30 characters, a subtitle of max 56 characters, a button verb)
  - first screen
  - notification permission
  - pick a leave time
  - armed
  - block info (what the curb rules are)
  - countdown
  - finished
  - "get the full app" moment
- **Rules:** a tight size budget, so reuse parts. No sign-up.
- **Screens:** 070–075.

### B12. Live Activity, Dynamic Island, lock screen
- **States:**
  - lock screen: armed countdown, "Leaving now" (a one-tap action that works without unlocking), leaving sent, thanks received, ended
  - Dynamic Island: compact, minimal, expanded
- **Rules:** v0.1 sets the lock screen to black with a taxi token, a countdown of 30/700, and a "Leaving now" taxi capsule 56 tall. Design every state in this family.

### B13. Notifications (copy + actions; iOS draws them in system type)
- Park reminders:
  - "Move your car by 9:00 AM" with actions Walk there / Remind me at 8 AM
  - the night-before reminder
- "Street cleaning suspended tomorrow"
- Spot Pass:
  - armed / leaving now / thanks / pass ended
  - driver reminders ("Still leaving around 4:15?" with actions Leaving now / 5 more min / Not leaving)
- Community: "Leaving soon near you"
- **Need:** final wording for each, deadline first, then the reason.

### B14. Plan a Trip (visitors, not live)
- **Job:** let a visitor see where they can park for their whole visit, and never mistake it for right now.
- **States:**
  - entry point
  - planner: arrival and departure date/time, quick picks (Today 5–10 PM, Tomorrow 9 AM–6 PM, This weekend Sat 10 AM–Sun 6 PM)
  - validation errors (arrival in the past, departure before arrival, over 7 days)
  - the trip map with the violet dashed frame and the striped "TRIP PLAN · NOT LIVE" tag with dates
  - curb verdicts
  - the street-cleaning calendar not available for those dates (e.g. 2027)
  - exit back to live
  - AX5
- **Screens:** 080–084.

### B15. More and Settings
- **More sheet rows:**
  - Report
  - Spot Pass / Your Spot Pass
  - How WePark works (replay tour)
  - What the colors mean
  - Parking 101 (Sign School)
  - Show all sign details (switch)
  - Plan a trip
  - Settings
- **Settings:**
  - reminders defaults
  - voice
  - notifications
  - account
  - **delete account** (with confirmation)
  - **suggest a neighborhood** (for areas outside Manhattan)
  - help / FAQ
  - about
- **Also:** "What the colors mean" (the legend for both 2-state and 5-state modes, plus live pin types).
- **Screens:** 014–018, 025, 114–118.

### B16. Parking 101 / Sign School
- **Job:** explain NYC parking signs simply.
- **Content:** the common sign types and how WePark treats them:
  - street cleaning
  - no standing vs no parking vs no stopping
  - meters
  - commercial-only meters
  - truck loading
  - taxi stands
  - diplomat/permit curbs
  - school days
  - temporary construction
- **Screens:** 116.

### B17. Web pages (getwepark.com)
- **`/p`** (Spot Pass web fallback for people without the app):
  - waiting with leave-time chips plus Pick a time
  - armed (keep this page open)
  - leaving sent
  - finished
  - report a pass
  - "Get WePark" (currently a TestFlight link)
  - unavailable / not live yet
- **The `getwepark.com` landing page:** what WePark is, plus a download link.
- **Screens:** 091–097.

### B18. Empty, error and edge states (app-wide)
- No location permission
- Location only "while using"
- Notifications off
- Offline
- Server down
- No curbs loaded
- Outside Manhattan
- Account / sign-in problems
- First launch with no parked car

---

## Proposed SF Symbols (Rounded, Semibold): confirm or replace (A3)

| Feature | Proposed symbol |
|---|---|
| Park / parked car | `car.fill` |
| Car token / park here | `parkingsign.circle.fill` |
| Start driving | `steeringwheel` |
| End drive | `xmark` |
| Search | `magnifyingglass` |
| More | `ellipsis` |
| Locate me | `location.fill` |
| Report | `exclamationmark.bubble.fill` |
| Street cleaning / swept | `sparkles` |
| Enforcement / ticketing | `exclamationmark.triangle.fill` |
| Temporary no parking | `cone.fill` |
| Blocked for filming | `video.fill` |
| Construction | `hammer.fill` |
| Open spot | `checkmark.circle.fill` |
| Leaving soon | `figure.walk.departure` |
| Spot Pass | `qrcode` |
| Hand off / pass your spot | `arrow.left.arrow.right` |
| Karma | `heart.fill` |
| Reminders | `bell.fill` |
| Voice on / off | `speaker.wave.2.fill` / `speaker.slash.fill` |
| Walk there | `figure.walk` |
| Plan a trip | `suitcase.fill` |
| A Few Hours goal | `hourglass` |
| Overnight goal | `moon.stars.fill` |
| For days goal | `calendar` |
| Show all sign details | `list.bullet.rectangle` |
| What the colors mean | `paintpalette.fill` |
| Parking 101 | `book.fill` |
| Settings | `gearshape.fill` |
| Chatter | `bubble.left.and.bubble.right.fill` |
| Left side / Right side | `arrow.left` / `arrow.right` |
| Time left | `clock.fill` |
| Metered | `creditcard.fill` |
| No data | `questionmark.circle` |
