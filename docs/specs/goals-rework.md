# Goals rework + Plan a Trip (spec, 2026-11-24)

Source: Kevin's decisions after the build 27 live smoke (`docs/sign-types-review.md` → "Kevin's decisions"), plus his Plan a Trip request. Product rule: never show green for a spot that isn't a spot; base colors are simple red/green; the app is for everyone with a car in NYC.

Builds on: `Services/ParkingGoals.swift` (goal targets, `match`, `goodThroughLabel`), `ParkingRulesEngine.isFree(segment:from:until:ignoringMeteredPayment:)` (already takes any window), `Views/GoalSelectorView.swift`, `Views/ParkUntilSheet.swift` (the existing clock "Park Until" flow), and the drive card's chip-color override (being unified with the map in the drive-card PR). Implement AFTER that PR merges.

## 1. One rule for "free"
- A curb is green for a window only if NOTHING restricts a private car anywhere in [start, end]: ASP (calendar-aware), No Standing/Stopping/Parking, truck loading, special/plate-only, the reclassified commercial-only and loading-only signs, temporary construction, AND **running meters**.
- Delete the per-goal metered tolerance (`ignoresMeteredPayment` → always false). Map overlay, drive-card chips, voice, and labels all call the same function (single source of truth).
- **Invariant, enforced by tests:** with the same start (now), green(A Few Hours) ⊇ green(Overnight) ⊇ green(Park & Forget). Property-test it over a sample of real tile segments at several times of day and week (incl. Sunday, ASP days, and suspension days).

## 2. Goals all start NOW, and every goal shows its window
| Goal | Window | Shown as |
|---|---|---|
| A Few Hours | now → now + 3 h (existing ruling) | "Now → 8:15 PM" |
| Overnight | now → next morning at **7:00 AM** (if it's already past midnight and before 7 AM, then today 7 AM; if it's 7 AM or later, then tomorrow 7 AM) | "Now → 7:00 AM tomorrow" |
| Park & Forget | now → the existing 8/4/2-day ladder (unchanged) | "Now → Mon 11/30" (the rung it clears) |

- **Overnight lever:** a small control on the Overnight tile/banner to set the morning end: 6, 7, 8, 9, 10 AM (default 7). Persist the user's choice. The banner and map update live.
- The banner replaces today's confusing "Overnight · Good through Thu" with the explicit window, plus, per curb on tap, "Free until <next restriction>".
- All window copy uses dates once 2+ days out ("Mon 11/30"), matching the drive-card date fix.

## 3. Plan a Trip (visitors, day trips, weekends)
**Who:** people NOT parking now: visitors, day-trippers and weekenders who want to avoid a $50+ garage. Must be unmistakably labeled as a future what-if so locals don't confuse it with "now".

**Entry:** a fourth, visually distinct option ("Plan a trip", suitcase/calendar icon) on the goal row or in the More sheet, NOT one of the three "now" tiles. Copy: "Coming into the city? See where you can park for your visit."

**Flow:**
1. Pick arrival (date + time) and departure (date + time). Quick picks: "Today 5 PM → 10 PM", "Tomorrow", "This weekend (Sat 10 AM → Sun 6 PM)". Arrival must be in the future (or now); departure after arrival; cap at 7 days.
2. The map recolors for [arrival, departure] with the same §1 rule. A persistent, distinct banner: "TRIP PLAN · Sat 11/28 10:00 AM → Sun 11/29 6:00 PM · not live", with an exit button. Use a different accent (not the live blue) so it never reads as "now".
3. Tapping a curb shows "Free for your whole trip", or "Not free: street cleaning Sat 11 AM–12:30 PM".
4. Optional: a "Save this plan" button that adds a reminder the morning of the trip to re-check (signs, film shoots, construction can change).
- **Caveat line** (always visible in trip mode): "Rules can change (film shoots, construction, holidays). Check the signs when you arrive."
- **Not in scope for v1:** garage prices, navigation, multi-stop trips. (Garage price comparison is a later idea: "you'd save ~$X vs nearby garages".)

**Engine:** `isFree(segment:from: arrival, until: departure, ignoringMeteredPayment: false)`. The day-walk already handles multi-day windows and the ASP suspension calendar. The ASP calendar must cover the trip dates (2026 file today; trips in 2027 need the 2027 calendar or must show "calendar not available yet").

## 4. Simple colors by default
- Base map and onboarding: two colors only, green (park) and red (don't).
- Existing richer states (metered amber, ASP-today, etc.) move behind a "Show all sign details" toggle in Settings/More, default OFF. Tapping a curb always shows the real sign text, so information is never hidden, only simplified.

## 5. Acceptance
- Invariant property test passes. Chip color == map color for the same curb and window (from the drive-card PR) still holds.
- At 1 PM on a Tuesday in NoHo, A Few Hours shows at least as much green as Overnight.
- Bowery commercial-only curbs are red Mon–Fri 8–6 in every goal (after the sign-reclassification PR).
- Overnight shows "Now → 7:00 AM tomorrow". Changing the lever to 9 AM can only remove green, never add it.
- Trip mode banner is always visible, uses a distinct accent, exits cleanly back to live, and never leaks its window into the drive card or voice.
- Flags: ship behind the existing `driveModeDefaultEnabled` world (goal row). Plan a Trip gets its own flag `planTripEnabled = false` until Kevin smokes it.
