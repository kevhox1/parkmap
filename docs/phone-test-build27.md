# Build 27 phone tests (Spot Pass + carried-over build 26 checks)

Build 27 is an INTERNAL TestFlight build with these switched on locally (main stays dark):
drive mode default, curb-pin placement, address line, Spot Pass, Spot Pass auto-detect
(background location), and the "I'm leaving" Siri/Shortcuts action.

**Before you start:** the orchestrator pastes the server switch-on SQL
(`update public.handoff_config set value='true' where key='HANDOFF_ENABLED';`) and you click Run.
Until then every Spot Pass step shows "isn't live yet". Only build-27 testers can create passes.

**You need two iPhones.** "Waiting phone" = the person who wants the spot and shows the QR.
"Driver phone" = the person about to leave, who scans it. Ideally the driver phone does NOT
have WePark installed (that's the App Clip path); repeat once WITH WePark installed.

Write down for each step: pass / fail / weird, plus the time. Screenshots help.

## A. The QR and the scan
1. Waiting phone: open WePark, start a Spot Pass, show the QR. Does it look good? Name/glyph right?
2. Driver phone: scan it with the Camera app from about 1 m, then through a car window (glare).
   Note the farthest distance that works.
3. Driver phone without WePark: the App Clip card should appear. (Until the App Store Connect
   App Clip card is set up, this may only work via TestFlight's App Clip experience. Note what happens.)
4. Driver phone with WePark: the scan should open the WePark app straight to the pass.

## B. Arming and the lock screen (the headline)
5. Driver: pick a leave time and arm. Waiting phone should get an "armed" notification.
6. Driver: lock the phone (passcode on). The Live Activity shows on the lock screen.
   Tap "Leaving now" WITHOUT unlocking. Waiting phone should get "they're leaving" within seconds.
7. Repeat with the reminder notification's buttons (5 more min / not leaving) without opening the app.
8. Waiting phone: after the handoff, send thanks. Driver's Live Activity should show the thank-you.

## C. Hands-free options
9. Driver phone with WePark: arm a pass, then tap Start Driving. It should send the heads-up.
10. Auto heads-up: arm a pass, opt in to auto heads-up, walk away from the car (should NOT fire),
    then drive off (should fire once). Note any false fires near tall buildings or in a garage.
11. Shortcuts: "I'm leaving" action appears in the Shortcuts app; try the "when my phone connects
    to my car" automation from the in-app guide.

## D. Edge cases (quick)
12. Airplane mode on the driver phone, tap Leaving now: the error copy should make sense.
13. Live Activities off in Settings for the clip: the clip should link you to Settings.
14. Driver installs WePark after using the clip: the pass should carry over.

## E. Still open from build 26 (`docs/drive-test-build26.md`)
15. Heading feel while driving, one real closure report WITH a photo, curb-pin placement on real
    streets (does the pin stay where you drop it now?), and the address line ("In front of …").
