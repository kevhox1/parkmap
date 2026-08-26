# WePark — Product Synopsis

> Written 2026-08-25 for the design workstream (Claude design / look-and-feel workshop).
> This is product framing, not engineering docs — for build state see `HANDOFF.md`.

## What it is

**WePark is a native iOS app that tells NYC drivers whether they can legally park on any given
curb, right now.** It reads the city's own parking-sign data and draws the answer directly onto the
map as colored lines along each side of every street.

Currently in external TestFlight beta. iOS only. NYC only — practically, Manhattan.

## Who it's for

**People who park on the street in New York City** and are trying not to get a ticket.

- **The experienced street parker.** Knows the rules, wants "can I leave it here?" answered in a
  glance, and above all wants to avoid the alternate-side street-cleaning ticket.
- **The newcomer.** Just moved to the city or just got a car. NYC signs are stacked, contradictory,
  and full of exceptions. For this user the app is also an explainer — there's a built-in
  "Parking 101" guide, and a stated goal of taking *someone who knows nothing about street parking
  and getting them to fully understand the game.*

## The core idea

Every curb is governed by signs most people can't parse quickly. WePark pre-parses them and renders
the answer as color:

- 🟢 **Green** — free parking right now
- 🟠 **Amber** — time-limited or metered
- 🔴 **Red** — restricted, don't park

**The colors are live**, evaluated against the current date and time. A block that's green at 2pm
turns red at 8am when street cleaning starts.

**The map is the product.** Not a list, not a search interface — a map you glance at while circling
the block.

## How it works

**Data.** NYC parking-sign regulations joined to NYC's street centerline dataset (CSCL),
preprocessed into map tiles bundled in the app. Lines are drawn offset to each side of the street,
because the rules differ per side. Coverage is roughly **half of NYC street-miles** — the city
hasn't digitized signs for every block; uncovered blocks render with no color rather than a wrong
guess.

**Three things the app does:**

1. **Read the curb.** Open it, see colors. Tap any segment for that block's rules in plain
   language. A "Park Until" filter recolors the map for a target time — "I need to leave it until
   Thursday at 9."
2. **Remember your car.** Save where you parked with one tap. Reminders fire before alternate-side
   street cleaning (15 min / 30 min / 1 hr / 2 hrs / night before). This is the daily-habit hook:
   the ticket you avoid is worth more than the spot you find.
3. **Crowd-sourced live conditions.** Users report what sign data can't know: **enforcement
   active** (an agent is ticketing this block now), **sweeper passed** (this curb is safe now), and
   **street closures** (film shoots / construction, photographed and submitted, overriding sign
   data for that block). Reports push to other users in real time over a WebSocket; ephemeral ones
   expire in minutes.

**Driving modes.** Navigate to a destination with parking-aware route selection, or **"Find a
Spot"** — drive with no destination while the app calls out parking conditions block by block.
Heading-up camera, voice guidance, designed for a windshield mount.

## Design constraints that matter

- **Always dark.** Not user-configurable.
- **Used in a car, in sunlight, on a windshield mount.** Legibility in direct sun is a real, tested
  requirement — one shipped color scheme already failed on it once.
- **Glanceable in 1–2 seconds** at a stoplight. That's the interaction budget.
- **Zero-friction onboarding.** No account, no login, no sign-up. Anonymous identity created
  silently on first launch. Open the app, see the map.
- **Navigation lives in a bottom sheet** modeled on Apple Maps: search field at rest, pulling up to
  a primary "Find a Spot" action and settings. Map controls — locate, find-my-car, Park Until —
  float top-right, outside the sheet.
- **Red / amber / green is load-bearing.** It's the app's entire information encoding and cannot be
  reassigned to decorative use anywhere in the UI.

## What it is not

Not a garage finder. Not a payment app. Not a reservation service. It doesn't tell you where an
empty space *is* — it tells you where you're **allowed** to park, and helps you not get towed.
