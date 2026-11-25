# WePark: design brief (open canvas)

This kit describes **what WePark must do and the rules it must follow**. It deliberately contains **no visual direction**: no styles, moods, references, palettes, typography or layouts. Every visual and interaction decision is yours. The screenshots in `screens/` show what exists today, for context only. Treat them as a record, not a reference.

The owner's ask: a bespoke, original visual and interaction language for every screen, built to make using the app as easy and as satisfying as possible. No pre-made styles or templates.

---

## 1. What WePark is
A free iPhone app for parking in New York City (Manhattan today). It reads every posted NYC curb regulation sign (~96,000 sign records from NYC DOT open data), turns them into curb-by-curb rules, and answers one question in real time: **can I leave my car here, and until when?** On top of that sit a community layer (neighbors reporting live conditions) and Spot Pass (a neighbor-to-neighbor parking spot handoff).

## 2. Who it's for
- **Primary:** people who live in NYC and keep a car on the street. They park daily or a few times a week, deal with alternate-side street cleaning, and circle for spots.
- **Secondary:** visitors, day-trippers and weekenders driving into the city who want to avoid garages (served by Plan a Trip).
- The owner's goal: "We want everyone using this app, and most importantly people who have a car in NYC and live here."
- Context of use: often **in a moving car** (glanceable, one-handed or hands-free), often **standing at the curb** reading signs, sometimes **planning ahead** at home.

## 3. Non-negotiable product rules
1. **Never show a spot that isn't a spot.** If a regular private car can't legally park somewhere for the time in question, it must not look parkable. When unsure, show it as not parkable. ("They will instantly be off the app.")
2. **The default view is simple: two states, park / don't park.** Richer detail (every sign category, meters, etc.) is available on demand for experienced users ("Show all sign details"), but it isn't the base experience or what onboarding teaches.
3. **The real sign data is never hidden.** Any curb can be inspected to see the actual posted rules.
4. **Every "free" answer is for a time window, and the window must be obvious.** Today's windows:
   - A Few Hours = now → now + 3 h
   - Overnight = now → next morning at a user-adjustable hour (6–10 AM, default 7 AM)
   - Park & Forget = now → several days out

   A shorter window must always show at least as much parkable curb as a longer one.
5. **Live vs not-live must be unmistakable.** Plan a Trip shows a future window and must never be confused with "right now". Live actions (park here, report, Spot Pass) aren't available while planning.
6. **Glanceable while driving.** Drive-mode information must be readable in a glance and operable with large targets, and must not require reading paragraphs. Voice guidance exists.
7. **Large touch targets.** The owner explicitly prefers big, roomy buttons, especially in drive mode.
8. **Accessibility.** Dynamic Type through the largest accessibility sizes without truncating critical information, VoiceOver, sufficient contrast in light and dark, and no reliance on color alone where it matters.
9. **Privacy.** Location never leaves the device except where a feature explicitly needs it. Spot Pass shares no identity or location with the other person ("They won't see who you are or where you are").

## 4. Platform constraints (technical, not stylistic)
- **iOS app, SwiftUI.** The map is **Apple MapKit**. The base map comes from Apple, and WePark draws curb lines, pins and overlays on top of it. The map is the primary canvas of the app.
- **Surfaces outside the app that must be designed too:**
  - **Live Activity / Dynamic Island / lock screen** (Spot Pass countdown with a "Leaving now" action that works on a locked phone)
  - **notifications** with action buttons
  - **App Clip** (a lightweight version opened by scanning a QR code, no install needed; strict size budget)
  - a **web page** (getwepark.com/p) for people without the app
  - the **App Store / TestFlight** listing
- Light and dark appearance. iPhone sizes from SE to Pro Max.
- Siri / Shortcuts actions exist ("I'm leaving").

## 5. Everything the app does (feature inventory)
**Map and rules**
- Curb-by-curb coloring for the selected window; tap a curb to see its rules, the next restriction and the real sign text.
- Goals: A Few Hours, Overnight (with an adjustable morning end), Park & Forget. Each shows its exact window.
- Search for a place; "Show all sign details" for the full palette.
- Alternate-side parking (ASP) awareness, including the official suspension calendar (holidays, snow), and a banner when ASP is in effect today.

**Driving**
- Drive mode: the map follows the car with a heading arrow. A card shows the current street and the rules for the curb on the **left** and **right** relative to the direction of travel. Voice announcements. Start / End.
- Destination mode with an arrival prompt ("park here?").
- Report a problem and park here, from drive mode.

**Parking**
- Mark where you parked: by placing a pin on the exact curb (snaps to the curb, shows the address, e.g. "In front of 50 E 1st St"), or "Park here".
- My Car: where the car is, how long it's been there, **how long it's legal**, reminders before the rules change (lead time plus "night before"), and "I left".
- Garage savings estimate (where shown).

**Community**
- Neighbors post live conditions on a block: street cleaning done ("swept"), temporary restrictions, blocked streets, and "leaving soon" pins to hand a spot to nearby drivers ("the crew").
- Block chatter (short messages on a block).
- Future (requested): Waze-style reports, "blocked for filming / construction / parking blocked", where the reporter marks the blocked part of the block with a pin or by dragging along it.

**Spot Pass: neighbor-to-neighbor spot handoff**
- Seeker (wants a spot): makes a pass in the app and shows a **QR code** to a driver who's about to leave.
- Driver (is leaving): scans the QR with the iPhone camera.
  - Without the app, it opens the **App Clip** (or the web page).
  - They pick when they're leaving: Now, ~10 min, ~30 min, ~1 hour, or **pick a clock time**, up to 4 h ahead.
  - A **lock-screen Live Activity** counts down with a one-tap "Leaving now" that works without unlocking. There are reminders, plus optional automatic "heads-up" when the car starts driving.
- The seeker gets real-time alerts (armed, leaving now) and can send thanks. Karma accrues for helpers.
- It's a key **onboarding funnel**: a stranger's first contact with WePark is often scanning someone's Spot Pass, so it must be an excellent first impression.

**Plan a Trip (for visitors)**
- Pick arrival and departure (quick picks: today evening, tomorrow, this weekend; up to 7 days). See which curbs are free for the whole visit, with a clear "not live" state and a caveat that rules can change.

**Settings / account**
- Notifications, voice, account (account deletion and "suggest a neighborhood" exist but are switched off today), help, and Sign School (explains NYC signs).

## 6. The job of each screen (what it must achieve, not how)
| Screen / moment | The job, in one sentence |
|---|---|
| First launch / onboarding | In seconds, make a NYC driver believe this will save them tickets and time, and get the permissions it needs without friction. |
| Main map | Show, at a glance, where I can leave my car for the window I care about, and make changing that window effortless. |
| Curb / block detail | Tell me, unambiguously, whether I can park on this exact curb, until when, and why (the real signs). |
| Drive card (moving) | Tell me in one glance which side of the street I can park on, without taking my attention off the road. |
| Parking a car | Let me mark exactly where I parked in a few seconds, at the right curb. |
| My Car | Answer "am I OK, and until when?" instantly; make reminders and leaving trivial. |
| Reminders and notifications | Get me to move the car before a ticket, at the right moment, without being annoying. |
| Community / reporting | Make it quick and rewarding to tell neighbors what's happening on a block, and trustworthy to read. |
| Spot Pass (seeker) | Make asking a stranger for their spot feel easy, safe and kind. |
| Spot Pass (driver / App Clip / lock screen) | Let a stranger with no app agree in seconds and tap one button when they leave, even with a locked phone. |
| Plan a Trip | Let a visitor see where they can park for their whole visit, and never mistake it for right now. |
| Settings / More | Find anything secondary without clutter on the main screens. |

## 7. Known pain points from owner testing (to solve, however you see fit)
- The My Car sheet "has too much going on".
- Drive-card left/right sides and colors were confusing when they disagreed with the map (now fixed in logic; the presentation of left/right for drivers still needs to be obvious).
- The three goals and their windows weren't clear ("Overnight means from now until the morning, not tonight").
- Parking is "pretty boring and stressful". The owner wants it to feel fun, interactive and useful, and the neighborly parts (Spot Pass, karma, helping) to feel rewarding.

## 8. What's in this kit
- `BRIEF.md`: this document.
- `screens/`: screenshots of every current screen and state, with `screens/INDEX.md` (how to reach each one).
- `FLOWS.md`: the main user flows step by step, as they work today (functional only).

## 9. Open questions you may want to explore (the owner hasn't decided)
- How the base two-state view and the detailed view relate.
- How left/right is best communicated while driving.
- How time windows are chosen and shown.
- How karma, helping neighbors and community trust are expressed.
- How the app's identity extends to the lock screen, App Clip, notifications and the web page.
