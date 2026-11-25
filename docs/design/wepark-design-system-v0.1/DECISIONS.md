# Owner decisions on the WePark redesign

## v0.1 handoff (Kevin, 2026-11-24)
- Adopted direction: 2a "Stoop, straight". Options 1a/1b/1c are NOT to be implemented.
- "Walk there": hand off to **Apple Maps** walking directions (no in-app routing).
- Build behind a flag (`designSystemV2Enabled`, default off) so the current design stays live until Kevin compares.

## Round 2 (Kevin, 2026-11-25), package `docs/design/wepark-round2/`
The round-2 screens (B1–B18) are the layout reference for every screen. Implement them, with the adjustments below.

### Proposals accepted
- **A1 Overnight lever:** "Change" beside the headline while Overnight is selected. It opens 6–10 AM hour chips, and the map and headline update per tap.
- **A2 App icon:** the yellow car token on a curb that turns from solid green to dashed coral, on an ink-violet field. Kevin: it adds a playful, gamified feel. The final glyph is drawn properly at 1024 × 1024. The "W" alternative is rejected.
- **A3 Icon map:** SF Symbols Rounded Semibold per the round-2 README. Left/right is always spelled out, never shown as an icon.
- "About 10 min" wording replaces "~10 min".
- The driver's auto heads-up is an opt-in switch, off by default.
- School-day signs count as in effect unless the app knows school is closed (DOE calendar, future).

### Adopted by default (orchestrator recommendation; Kevin can override)
- **Goal rename:** "Park & Forget" becomes **"For days"**. The window stays adaptive: the existing 8 → 4 → 2 day ladder (`ParkingGoals.parkAndForgetLadderOffsetDays`). The headline and tile show the **actual end date the ladder picked**, never a hard-coded week. The sparse-map line ("Only a few blocks nearby are clear for …") uses the real span.

### Accuracy adjustments (override the mocks; rule: never show a spot that isn't a spot)
1. **No sub-curb precision claims.** The data can't place an arrow sign to the foot or tell whether a car is "past" it. Drop "First 20 ft from 2nd Ave" and "Your car is past it" (B4.11, B7 signs sheet). Arrow/corner signs read: "Arrow sign — applies near the corner. Check the sign on the street." An arrow-limited restriction never turns the curb's verdict green.
2. **"Open spot" pins** draw only on curbs that are green for the selected window. On a red, no-data or metered curb the pin is suppressed in the map. Where it's still shown in a list, it reads "Reported open — check the signs".
3. **"Neighbors say" never makes a curb greener.** Swept, "it's gone" and other confirmations only add info. The sign verdict stands (as B4.9 already shows).
4. **No data draws as don't** on the base map. Grey "no sign data" lines appear only with "Show all sign details" on. The verdict block still says "No sign data — read the posted signs."
5. **Counts must be real.** "6 free curbs within 2 blocks" (B3.3) is computed on device from loaded segments for the selected window. If tiles aren't loaded, the count is hidden; it is never estimated.
6. **Times come from the engine.** Every "Free until / You'd have to move by" uses `ParkingRulesEngine` results. Midnight is written as "midnight" (follow-up from the build-27 smoke).
7. **App Clip notifications:** the clip schedules **one** reminder, matching the copy "That's the only notification you'll get." (Today it schedules two.)
8. **Reminder lead times:** one option set everywhere: 15 min, 30 min, 1 hr, 2 hr, multi-select, plus "the night before". Used by both My Car (B7.6) and Settings (B15.3).
9. **More sheet:** use the fuller B15.1 list everywhere (B14.1 is an excerpt).
10. **Drive mode ground:** MapKit can't be recolored to the mock purple. Use the dark map style plus an ink tint overlay. The target is the look, not the exact pixels.

### Needs backend work (later phase, not a reskin)
- Marking a stretch of curb with two drag handles (start and end along the curb) on community pins.
- "Still there / It's gone" confirmations and the "n neighbors confirmed" count.
- Karma for reports (+2) and confirmations (+1), plus a karma history list. Today karma is handoff-only.
- An optional first name on a Spot Pass.
- Block rules inside the App Clip (B11.6): a network fetch of one curb's rules, within the clip size budget.
- A "No parking today" report type (map to an existing pin type or add one).

### Build order (all behind `designSystemV2Enabled`)
1. Foundation (tokens, fonts, components, round-2 parts) compiling, plus the app icon.
2. Map: goal sheet, lever, toolbar, banners, map states, then curb sheet and search.
3. Drive mode.
4. My Car and drag-to-park.
5. Spot Pass (seeker and driver), App Clip, Live Activity, notifications, web /p.
6. Onboarding, coach marks, Plan a Trip, More/Settings, Parking 101, error and empty states.
7. Community backend additions.
