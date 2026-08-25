# WePark — Use Cases & Vision

> Written 2026-08-25 with Kevin, for the design workstream. Short forms were cut to ~400 characters
> at his request for pasting into design tools; long forms preserved here as the reference.

## Three core use cases

### 1. The Day-Tripper

Drives into Manhattan for a meal or a show. Lives elsewhere, knows nothing about NYC parking rules,
has always defaulted to a garage — and the garage wants $45. Willing to try a free spot but the
signs read like legal documents and guessing wrong means a ticket or a tow.

Needs: to know free parking near the destination exists at all; which specific curb is legal, in
plain language; reassurance they've read it right; when they must be back.

The only user who'll read explanatory text — usually stopped or on foot, so the one case with a
real attention budget. Rare (a few times a year) but it's the first-run experience and the best
word-of-mouth moment.

### 2. The Manhattan Resident — the core user

Street-parks, moves the car for alternate-side cleaning, has been ticketed and remembers the cost.
Never browsing; three triggers only: *do I need to move it?*, *where do I move it to?* (often 8am,
in pajamas), or a notification fired.

Needs: a reminder with enough runway to get downstairs; to know if cleaning is **suspended** today
so they don't move for nothing; a fast read on nearby blocks; eventually suggested moves that turn
a hunt into a directed trip.

**⚠️ The defining constraint — this app is not for browsing.** Kevin: *"I don't want a Manhattan
parker on the app at all times. It's not for fun. It's practical."* Success is **low engagement**:
the notification is the primary product surface, the app is what you open because it fired,
sessions last seconds, no feed, no streaks. The ideal user opens it twice a week and never gets a
ticket. Frequency 2–4×/week — the retention engine.

### 3. The Spotter — speculative, not built

A non-parker (pedestrian, dog-walker, delivery driver) who sees a car pull out, reports the open
spot, and earns karma / vouchers. Nearby drivers with notifications on get told.

Honest problems, stated plainly: a Manhattan spot lasts on the order of a minute, so reporting
*specific spots* mostly delivers disappointment — reporting **turnover** ("this block is moving
right now") survives that with a longer useful life and no promise to break. Cold-start is real:
neither side works without the other. And the spotter gets no parking benefit, so the hard part
isn't tech — it's why they'd install the app at all. (Plumbing partly exists: `open_spot` is
anticipated in the schema as unbuilt scope, and anonymous identity + a reputation field ship
today.)

### Together

Three different things from one map — *explanation*, *speed*, *frictionless contribution* — and
the retention engine explicitly does not want to be engaged. Any design that increases the
resident's time in the app is working against the product.

## Vision

**Every Manhattan street parker uses this app.**

Unusually achievable, because the market is finite and dense: low hundreds of thousands of street
parkers in 23 square miles. Most consumer apps chase an unbounded market and settle for a sliver;
this one can plausibly reach **saturation** — and saturation is the point, because the product gets
better as it approaches it.

**The wedge is the ticket, not the spot.** Finding parking is a nice-to-have people muddle
through. Not getting a $65 street-cleaning ticket is a recurring, quantified, calendar-driven pain
with a hard deadline. Retention is structural rather than engineered — alternate-side creates the
habit twice a week, forever. Earn trust on the ticket and you own the parking relationship by
default.

**Density is the compounding asset.** Sign data is public; anyone could rebuild it. What can't be
copied is a live layer of *who is ticketing where, right now* — and the network effect is
**per block**, not citywide. A user in the East Village makes the map better for their neighbors
immediately. The app is useful at 5% penetration on one block long before it's useful at 5% of the
city; growth happens block by block, which is how a small market gets saturated.

**The path is sequential:** coverage → trust → habit → density → suggestion. Sign coverage sits
near half of street-miles, which caps trust — a wrong or missing block costs more credibility than
a right one earns — so coverage is the gating investment, not features. Then the endgame becomes
possible: *"move it to the north side of your block, legal until Thursday."*

**The honest tension:** deliberately low-engagement, which is hostile to every standard growth
loop. Distribution has to come from the thing being worth mentioning — the neighbor who stops
getting tickets.

**Success looks like infrastructure.** Not an app people love — an app people simply *have*, like
the weather. The default answer when someone in Manhattan buys a car and asks what they should
know.

### 400-character version (for design tools)

> **Every Manhattan street parker uses this.** A rare finite market — hundreds of thousands in
> 23 sq miles. Saturation is reachable. The wedge is the **ticket**, not the spot: alternate-side
> builds the habit twice a week, forever. Density compounds **per block**, useful long before it's
> citywide. Not an app people love — one they simply *have*, like the weather.
