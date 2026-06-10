# NYC Neighbors — Community Incentives & Contribution Economy (Concept)

**Status:** Concept / strategy doc — NOT a build order. Living document.
**Origin:** Kevin + ideation session, 2026-06-09.
**Roadmap placement:** a growth/community layer that rides on Tier 2 (reputation) + Tier 3 (open_spot)
and feeds the Smart Parking Route (2.0). Phased — an intrinsic v0 is cheap and near-ish; the
brand-rewards economy is a later, deliberate program. Related: `docs/business-model.md`,
`docs/smart-parking-route-2.0-concept.md`, `docs/community-1.0-direction.md`.

---

## 1. The opportunity

Turn WePark from a utility into a *community*. The hard problem for any user-generated parking data
app is **contribution** — who reports sweepers, open spots, sign corrections, and *why would they?*
A real "good neighbor" contribution layer is the differentiator and the supply side of the whole
flywheel (more contributors → better data → better Smart Route → more users → more contributors).

## 2. Core reframe: walkers/non-drivers are the supply side

Drivers are the *demand* side but **terrible suppliers** — they're moving, stressed, and can't safely
report while hunting for parking. The people who actually **see** open spots and sweeper trucks all day
are stationary and not in a hurry: **doormen, baristas, bodega clerks, dog-walkers, delivery workers,
stoop-sitters.** This is a Jane Jacobs "eyes on the street" network. Mobilizing *non-drivers* as the
reporting corps is how you beat the cold-start supply problem that kills most UGC apps.

The community story shifts from "drivers helping drivers" to **"the neighborhood helps the neighborhood
park"** — warmer, more civic, far more recruitable.

## 3. Frictionless reporting (the make-or-break for supply)

A non-driver gets **zero direct benefit** from parking data, so a report must cost **~2 seconds and zero
thought.** The moment it's a form, walkers churn. Design targets:
- One-tap report — home-screen widget / lock-screen / Apple Watch tap that auto-geotags.
- Photo capture as a single action (proof + content in one).
- No mandatory fields; everything else inferred (location, time, nearest segment).

**Friction is the #1 supply-side risk.** Reward + identity only matter if the *act* is effortless.

## 4. Incentive layers (stack them; don't jump to coffee)

1. **Identity / status (cheap, powerful):** "Good Neighbor" badges, neighborhood leaderboards,
   "Mayor of Mott St," contribution streaks. Builds the habit + the reputation spine (ties into the
   planned Tier 2 reputation system).
2. **Reciprocity / karma:** "You've helped 41 neighbors park." Fairness loop; helpers earn credibility
   (and potentially better signal quality when *they* need parking).
3. **Points → rewards (the accelerant):** "rewards dollars" / coffee vouchers — layered *on top* of the
   identity system, not the foundation.

## 5. Reward economy & brand partnerships ("NYC Neighbors / Good Neighbors")

This is a **business model**, not just a feature. The loop:
- A local café sponsors rewards → its regulars/staff earn credits redeemable *there* → the shop gets
  **recurring local foot traffic + brand love + a civic "Good Neighbor of [neighborhood]" halo.**
  WePark charges a monthly sponsorship (± a redemption cut).
- **Hyper-local:** rewards redeemable in the *same* neighborhood where reports happen — value stays
  local, the brand gets exactly the audience it wants.
- **Monetizes at tiny scale:** ~10 cafés × a small monthly sponsorship is real revenue *before* a huge
  user base — ideal for an indie app. A cheaper, more loyal, civic-halo alternative to a Yelp/IG ad.
- **Locked-to-sponsor vs. network credits:** locked credits sell the partnership better (exclusive
  brand benefit, drives loyalty); a network "rewards dollars" currency is more flexible for users.
  Likely start locked, evolve toward a network. (Open question.)

## 6. Key design insight: reward what's VERIFIABLE + DURABLE, not fleeting open-spots

An **open spot** is the *worst* base for a reward economy: gone in ~60s (tiny value window) and nearly
impossible to verify (filled before anyone checks → was it ever real?). It's a fraud magnet.

Reward the **durable, checkable** contributions instead:
- **Sweeper sightings** — cross-confirmable by others on the block; valuable for a window.
- **"Free till Thursday" / sign corrections** — durable, checkable against the rules engine, valuable
  for days.
- **Photos of signs/sweepers** — proof + content.

Treat fleeting "spot open now" as a low/no-reward, best-effort signal (still useful for the Smart
Route's coverage — just not something you mint coffee for). **This single reframe kills most gaming
before it starts.**

## 7. Anti-gaming / trust (the verification spine)

Paying points for reports invites fraud. Photo proof is the cornerstone (Kevin's idea): a photo is
better data, fraud-resistant evidence, AND shareable content. Stack:
- Photo + geo + timestamp → auto-trust score.
- Cross-confirmation by other users (the existing confirm/dispute system) gates payout.
- Reputation weighting, rate limits, captcha before redemption.
**Verification isn't a tax on the rewards program — it IS the product. No trust, no rewards.**

## 8. Go-to-market: hyper-local cold start

Don't launch citywide — make **one neighborhood magical**, then expand block by block. Seed reporters
aren't random walkers; they're people *already paid to watch the block*:
- **Doormen** — watch their curb all day, know the sweeper schedule cold. A "Doorman partner" tier is a
  phenomenal sensor network.
- **Baristas / bodega clerks** ("the coffee girls") — report from their workplace block, paid in *their
  own shop's* credits (zero cost to WePark, pure loyalty for the shop).
- The café becomes the **Good Neighbor sponsor** of that micro-area; its staff seed the data, locals get
  coffee, the block gets parking intel. The whole flywheel in a few blocks.

## 9. ⚠️ Legal guardrail (non-negotiable)

Apps that let people **sell / reserve / auction public street parking** have been **banned** (SF + NYC
cease-and-desists — MonkeyParking et al.). WePark must stay firmly on the **information & community**
side: *reporting* an open spot or incoming sweeper = fine (civic info). *Paying someone to physically
hold / control a public spot* = illegal. **Rewards are for contributing information, never for
controlling a spot.** Bake this in from day one.

## 10. Phasing

- **v0 (cheap, near-ish):** intrinsic only — "Good Neighbor" identity, badges, neighborhood leaderboard,
  "thanks" from helped drivers, streaks. Builds the habit + reputation/trust spine. Folds into Tier 2.
- **v1:** non-monetary points + status tiers + **photo reports** (better data + fraud-resistance,
  shipped before any money is on the line) + the frictionless one-tap capture.
- **v2:** brand-partner "rewards dollars" — launched **one neighborhood at a time** where there's
  density + a working verification system + a signed local sponsor.

## 11. How it connects to the rest of WePark

- **Tier 2 reputation** — the identity/trust layer (v0) is literally the reputation system.
- **Tier 3 `open_spot`** — the contribution surface; this concept supplies the *motivation* for it.
- **Smart Parking Route (2.0)** — more contributors (esp. walkers reporting open spots) = the occupancy
  signal that upgrades the route optimizer from "coverage proxy" to "route me to an actually-open spot."
  **Same flywheel.**

## 12. Open questions (for when we spec it)

- **Sponsor economics:** does the per-neighborhood sponsorship actually pencil out? Pricing model
  (flat monthly vs. redemption cut)?
- **Locked-to-sponsor credits vs. a network "rewards dollars" currency** — which first?
- **Non-driver hook:** is civic pride enough, or is it coffee-or-nothing for walkers?
- **Product surface:** what does a "Good Neighbor" actually see/do — a block feed? a leaderboard? a
  contribution streak? a photo feed?
- **Frictionless capture mechanism:** widget vs. lock-screen vs. Watch — what's the 2-second path?
