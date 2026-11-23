# Build 26 drive test — Kevin's card

Read this on your phone before you drive. Build 26 is the internal flag-on build: the driving-look launch, goal tiles, minimal rail + More, and curb-pin placement are all ON. Onboarding is NOT in 26. Have a passenger take notes, or use voice memos. Don't tap the phone while you're driving.

## 1. Heading feel (the headline)

When the map points the wrong way, note **WHEN** it happens. Every behavior maps to a named knob, so "when" is what lets us tune it:

| What you see | Likely knob | Now |
|---|---|---|
| Wrong way **at the very start** of a drive | stale browse rotation at entry (open item #45) / `flipConfirmFixes` | 2 fixes |
| Wrong way **right after a stop** (light, double-park) | freeze-on-stop gate `DRIVING_HEADING_MIN_SPEED_MPS` | 0.5 m/s |
| **Slow to catch up** after a turn | `DRIVING_HEADING_EMA_ALPHA_HIGH` / `_HIGH_SPEED_MPS` | 0.65 above 6 m/s (~13 mph) |
| **Jittery / wobbly** at crawl speed | `DRIVING_HEADING_EMA_ALPHA_LOW` / `_LOW_SPEED_MPS` | 0.35 below 2 m/s (~4.5 mph) |
| Brief **freeze** in a tight turn | `maxCourseAccuracyDeg` (bad-GPS rejection) | 45° |
| **Snaps 180°** when reversing / U-turn, or refuses to | `flipThresholdDeg` / `flipConfirmToleranceDeg` | 120° / 30° |

A verdict as short as "felt right", or "laggy after turns, otherwise fine", is enough.

## 2. TF2-16: heading at intersection approaches

This has **never been deliberately watched**. As you approach and roll through 3–4 intersections, does the chevron stay pointed down your street, or does it swing toward the cross street early?

## 3. One real closure report WITH a photo (#43)

Parked or stopped safely, file one real closure report with a photo attached. It proves the evidence-upload path fix (uploads were likely 403ing since ship). Afterwards, tell me roughly when you filed it so I can check that it landed.

## 4. Goal-first, in the real world

Launch → pick a goal tile (e.g. "A Few Hours" / "Overnight"). Do the green blocks match what the signs actually say? Does the drive card agree with the map? If the voice says "free on the left" while the card shows red, that's #44. Note where.

## 5. Curb-pin placement on real streets

Park, then place your pin. Does it snap to the correct street and side? Does the label ("Street · side · status") match the curb you're on? Does the 2 m side-switch dead-band feel right, or sticky?

## 6. Sunlight legibility

On a bright day, are the curb highlight, placement card, and goal tiles readable at a glance?

## Report back

For each section, send a one-line verdict plus any "when/where" notes. That's what drives the #37 flip decisions, and judging #44/#45 waits on this drive.
