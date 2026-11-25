# WePark: main user flows (functional, as they work today)

These steps describe behavior only. They're not a recommended design; any flow can be restructured as long as the requirements in BRIEF.md hold.

## 1. Find a spot near me (no driving)
1. Open the app. The map centers on me, and curbs are colored for the current window.
2. Choose a window: A Few Hours, Overnight (now → 7 AM by default, adjustable 6–10 AM), or Park & Forget.
3. Pan or zoom; tap a curb for its rules, the next restriction and the real sign text.

## 2. Drive and look for a spot
1. Tap Start Driving (or enter a destination).
2. The map follows the car. A card shows the current street and the rules for the curb on my left and right, in my direction of travel. Optional voice.
3. Near a destination, an arrival prompt asks whether to park here.
4. End the drive.

## 3. Park
1. Choose Park here, or place a pin on the exact curb. The pin snaps to the nearest curb and shows the address.
2. Confirm. The car is saved (on-device / iCloud).
3. Reminders are scheduled before the curb's next restriction (lead time plus an optional "night before").

## 4. Check on my car / leave
1. Open My Car: location and address, how long since parking, how long it's legal, the real rules, reminder settings.
2. When leaving: optionally post a "leaving soon" pin for neighbors, start a Spot Pass, or just clear the car ("I left").

## 5. Report something on a block
1. Long-press a block, or use Report.
2. Choose what's happening (e.g. swept, temporary restriction, blocked). It posts to neighbors and expires automatically.
3. Others see it on the map and in the block detail; block chatter lets neighbors add short messages.

## 6. Spot Pass: seeker (wants a spot)
1. Create a pass. The app shows a QR code with a friendly alias and glyph.
2. Show the QR to a driver who's about to leave.
3. Get alerts as the driver arms the pass and taps "Leaving now". Send thanks; helpers earn karma.

## 7. Spot Pass: driver (is leaving)
1. Scan the QR with the iPhone camera. With WePark installed, the app opens; otherwise the App Clip (or the web page) opens. No sign-up.
2. Pick when you're leaving: Now / ~10 min / ~30 min / ~1 hour / Pick a time (up to 4 h).
3. A lock-screen Live Activity counts down; reminders arrive. Optionally turn on automatic heads-up when the car starts moving, or Start Driving to send it.
4. Tap "Leaving now" (works on a locked phone) or "5 more min" / "Not leaving". See the thanks.

## 8. Plan a Trip (visitor)
1. More → Plan a trip. Pick arrival and departure, or a quick pick.
2. The map shows curbs free for the whole visit, under a "not live" trip banner with a caveat that rules can change.
3. Tap a curb: "Free for your whole trip", or the reason it isn't.
4. Exit returns to live.
