# Parking Hunt: problem brief and decisions

Date: 2026-11-27. Author: PM. For Kevin to workshop. Not a spec. Source: field log F-2, `docs/smart-parking-route-2.0-concept.md`.

## What we already have (so we don't rebuild it)

- **Drive mode with a destination** (W8.5a-d): address search, Mapbox route (up to 3 alternatives, scored for parking exposure), voice, final-approach prompt, "Park here".
- **Cruise / "Find Parking"**: no destination. Map follows you, one voice line per block, silent on all-red blocks. Plus the 5-item sign-check before you drop a pin.
- **Tile data per blockface**: rules, "free until", one-way flag and direction (`oneway`, `onewayToward`). Citywide one-way graph exists.
- **Old PWA "Find Parking Near Me"**: greedy sweep that respected one-ways. It replaced a harder solver because it behaved better on real streets. Not ported to iOS.
- **Plan a Trip**: times only, no address (F-1).
- **Not there**: no loop builder, no waypoints sent to the router, no turn bans, no live "is a spot open" signal, no analytics.

So the gap is small: **a planner that turns "destination" into "a loop that passes the best curb."** Everything else is wiring.

## 1. Who and why

**Who:** a driver heading somewhere in Manhattan who dreads the last 10 minutes. New users are the target. They have not yet seen WePark pay off.

**The moment:** "I'm going to W 33rd St. Where do I even look?" Today the app shows a map. It does not give a plan.

**Why it sticks:** the first trip delivers a clear win. Type address, press Go, get a short loop of free curb near it. It also gives a reason to open the app before every drive, not just after parking.

**Done feels like:** "It took me straight to the right blocks, and I parked within a couple of passes." If no spot shows up, the app says so honestly and offers a garage. It never claims a spot is open.

## 2. What "optimal" could mean

Test destination for each: **Penn Station area, W 33rd St, 7 PM Tuesday.**

| # | Definition | Example | Pros | Cons | Data needed |
|---|---|---|---|---|---|
| A | **Coverage**: pass the most legal-free curb | Loop W 31st, 8th Ave... picks the blocks with the most green length, even if 5 blocks away | Easy to explain. Uses data we have. | Can send you far from where you're going | Rules, one-way |
| B | **Durability**: favor spots that stay free longest | Prefers a block free until Thursday over one that flips to sweeping at 8 AM | Fits our "Park Until" promise. Real tow-risk value. | Alone, it ignores distance | "Free until" (have it) |
| C | **Closest walk** | Ranks free blocks by walk to 33rd St | Matches what people want | Closest blocks are the most crowded. We can't see that. | Rules, geometry |
| D | **Fastest expected park**: drive time plus chance of finding a spot | Picks the loop with the lowest time to a spot | Closest to the real goal | Needs occupancy odds, which we don't have. We'd be inventing the odds. | Occupancy (missing) |
| E | **Blend** | Score = free now x lasts long enough x near destination | Best of all | Needs tuning on real drives | Same as A to C |

**Honest limit:** we don't know which legal curb is physically full. Any "chance of finding a spot" number would be a guess. So v1 should not claim one.

**Recommendation: v1 = a simple blend of C, B and A, in plain terms:**
1. Only blocks that are legally free **now** and stay free for the user's stay (Park Until default, or 2 hours).
2. Rank by **walk distance to the destination**. Penalize blocks that flip to restricted soon.
3. Pick the **loop that passes the most qualifying curb within the walk radius** (coverage), because passing more curb is our only stand-in for "more chances."

Why: it uses only data we trust, it matches how a local actually hunts (get close, circle), and we can explain it in one sentence: "We loop the blocks within a 5-minute walk that are legal and stay free for your stay." D waits for the crowd `open_spot` signal.

## 3. How the route logic could work

1. **Radius.** Start at a 3-minute walk (~250 m) from the destination. Collect blockfaces that are green for the stay. Unknown, unclear and commercial signs are excluded (red).
2. **Score each block:** nearness x how long it stays free. Short slivers under one car length (6 m, already our rule) don't count.
3. **Build the loop.** Start at the nearest entry point on the user's path. Chain the best blocks along **directed** street edges. Greedy with a simple local fix-up, like the old PWA sweep. It must:
   - go the legal way on one-ways;
   - drive each block in the direction that puts the free curb on the usable side;
   - avoid U-turns and repeat streets (prefer right-hand loops of 4 to 6 blocks);
   - cap the loop at about 8 minutes of driving (Kevin's decision, see Q2).
4. **Expand.** If you finish a loop and haven't parked, widen the radius one step (3 to 5 to 8 minutes' walk) and give a new loop. Say so out loud: "Widening the search."
5. **Give up.** After 2 widened loops or about 15 minutes, or if no green block exists in the final radius, show: "No street parking near here. Garage 1 block away, $22." That's C1 in `revenue-concepts-brainstorm.md`. v1 can show nearby garages without prices. Prices need the affiliate feed.

**What the tiles support today:** rules, free-until, one-way flag and direction, side of street, geometry. Enough for v1.

**Missing:** turn bans (we can't tell a legal left turn), live occupancy, garage data and prices, and whether the street is blocked or under construction. The loop must tolerate approximate turns, and the router (Mapbox) should handle the real turn legality when we send it the waypoints.

## 4. Delivery options

**Apple Maps facts (checked 2026-11-27):**
- Apple's Map Links doc says only `daddr` is required, and `saddr` defaults to current location. It documents one destination ([Map Links](https://developer.apple.com/library/iad/featuredarticles/iPhoneURLScheme_Reference/MapLinks/MapLinks.html)).
- Multiple `daddr` values in one URL are reported to work by community sources. **Unverified, not in Apple docs.**
- MapKit's `openMaps(with:launchOptions:)` takes map items ([Apple docs](https://developer.apple.com/documentation/mapkit/mkmapitem/openmaps(with:launchoptions:).md)). I found nothing saying it builds a multi-stop route. **Unverified.**
- Apple Maps has multi-stop routing for users since iOS 16 ([MacRumors](https://www.macrumors.com/how-to/use-multi-stop-routing-maps/)), but I found no documented way for an app to hand it a ready-made loop.
- Developers report raw coordinates in `daddr` getting snapped to nearby places ([forum](https://developer.apple.com/forums/thread/751832)). Not reliable for "turn left here" geometry.
- From memory, not verified today: `MKDirections` takes one source and one destination, no waypoints.

**Bottom line:** you can't reliably hand Apple Maps a loop. At best you hand it 1 to 3 stops, and it may re-route you around our intent.

| Option | Pros | Cons |
|---|---|---|
| (a) In-app turn-by-turn | We control the loop. Our voice and green overlay are on screen. Mapbox allows many waypoints. Drive mode and cruise already exist. | We must do guidance well and keep it safe. No turn-by-turn voice today beyond parking cues (W8.5b excluded it). |
| (b) Apple Maps handoff | Zero guidance work. Users trust it. | Can't carry a loop. Leaves our app, so we lose the parking overlay and voice at the key moment. |
| (c) Hybrid: Apple Maps to the area, WePark runs the loop | Honest split. Cheap to start. | Handoff in and back is clunky. Two apps while driving. |

**Recommendation: (a), but narrow.** Draw the loop on our map with a big next-turn banner, reuse drive mode, and speak turns plus parking cues. Offer **"Get me there first in Apple Maps"** only as a secondary button for the drive from far away. That makes (c) a small add-on, not the core.

**Safety and App Store rules.**
- Our cruise voice is already tuned to short sentences. Keep it that way, and keep the ride-along rule: no typing while moving. Destination and settings only when stopped.
- Big touch targets and Dynamic Type at the largest size on the drive overlay. No small text.
- Apple's review guidelines on physical harm (1.4) apply to driving apps. I have not re-read the current text today. **Have `@qa-verifier` or a human read the current guideline before submission.** Do not describe the loop as "guaranteed" or "the best route" in the App Store text.
- Mapbox terms for in-app navigation: not checked. **Check before shipping (a).**

## 5. Smallest first version (v1)

**"Hunt this destination."** Reuse the destination search. After picking an address, one big button: **Hunt for parking**.
- Draws one loop of at most 8 minutes around the destination, using the blend in section 2.
- Uses existing drive mode, with a next-turn banner and our parking voice.
- "Park here" ends it. "Widen" gives the second loop. Then the garage message, with no prices yet.
- Manhattan only. Outside coverage: say so.
- Behind a flag, internal TestFlight first.

**Out of v1:** live occupancy, prices, Plan a Trip address (F-1, a separate small ticket that feeds this), Apple Maps loops.

**How we measure with no analytics.** Lightest honest signals:
1. **Kevin's drive tests.** Per drive: minutes from "Hunt" to "Park here", loops used, and whether the spot was real. This is the main signal for now.
2. **A tiny counter in Supabase** (unattributed event rows: hunt_started, hunt_widened, park_here_tapped, gave_up). Needs Kevin's OK since it adds a data collection. No personal data.
3. **TestFlight feedback** with one question: "Did the loop find you a spot?"

**Pick-up signal:** in 5+ real drives, parked within 2 loops at least 60% of the time (my threshold, an estimate), and testers use it a second time unprompted.

## 6. Questions for Kevin

1. **Is v1's "optimal" the C+B+A blend in section 2?** Recommend yes. D waits for occupancy.
2. **Detour cap?** Recommend about 8 minutes per loop, then widen once, then offer a garage at about 15 minutes total.
3. **In-app guidance or Apple Maps?** Recommend in-app (a), with an optional "Apple Maps to get there" button.
4. **Should the stay length default to 2 hours, or ask "How long?"** Recommend default 2 hours, tap to change, so there's no extra step.
5. **OK to add anonymous Hunt counters?** Recommend yes: four event types, no names, no locations beyond the destination's neighborhood.

## Risks
- Occupancy is unknown, so a "good" loop can still be full. Copy must say "free curb on this loop," never "you will find parking."
- Loop quality needs real driving to tune. Budget 3 to 5 drive tests.
- Red-curb clutter at wide zoom (R35-4) will make the loop hard to read until it's fixed. A Hunt map should show only the loop and the green blocks.
