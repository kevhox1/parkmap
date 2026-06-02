# WePark — Community 1.0 Product Direction

**Status:** Product-direction anchor (not an engineering spec). Date: 2026-06-01.
**Audience:** `@tech-lead` (specs the build from this), `@backend-data` (Tier 1 ingestion), `@ios-engineer` (pin UI + reporting).
**Supersedes nothing; reframes:** the `HANDOFF.md` three-layer model (Parked-car / Community / Drive Mode) — sharpened into a two-segment funnel with a cold-start-sequenced build order.

---

## 1. The correction that produced this doc

An earlier framing demoted Drive Mode / parking-status data to "a feature" and elevated community to "the 1.0 story." **That was wrong.** The corrected position:

> **The core parking-status data (static rules + Drive Mode) is the critical piece.** It is the hero for the person who needs it most. **Community is additive** — it serves a *different person* at a *different moment*, and it is the layer that keeps the core data *true today*.

Community is not a separate movement competing with the map. It is the real-time + correction layer **on top of** the map.

---

## 2. Two segments, one flywheel

| | **The novice / visitor** | **The experienced parker** |
|---|---|---|
| Who | Comes in on a random Tuesday, scared of the signs | Knows the block, knows the rules |
| Needs | The **rules** — where's free, what's that sign mean, Drive Mode | The **deltas** — what's *different today* |
| Value | "I can park here for free. I never knew that." | Reminders + real-time exceptions |
| Role | **Consumer** of data | **Producer** of intel |
| Funnel stage | Acquisition + activation | Retention + supply |

They are not two products — they are a **flywheel**. The experienced parker is the **supply side**: she reports the filming closure, the sweeper that already passed, the wrong sign. Her contribution becomes the novice's value. Some novices live here and graduate into experienced parkers, becoming supply themselves.

**Static = the law. Community = the law, as actually enforced on this block this morning.**

The static layer tells people the **rules**; it does not tell them today's **reality** (filming, construction, ASP-suspended-today, sweeper already came, sign is wrong). That gap is exactly where confident parkers still get burned — and exactly what community fills.

---

## 3. Why this de-risks cold-start (the key strategic property)

A community app that opens empty is dead. WePark has a bridge most don't:

1. **The static core delivers standalone value at zero other users.** A visitor gets "park free here" on day one with nobody else on the app. This buys time to reach the density community needs.
2. **Some deltas are open data — seed them, don't wait for users.** NYC film-shoot permits (streets held for parking), the ASP suspension calendar, and some DOT closures are published. "No parking — filming on this block" can be **pre-populated from the city** before a single user reports it.

So cold-start is solved in two layers: the map carries the novice; open-data deltas carry the early experienced user.

---

## 4. The delta taxonomy (backbone of the 1.0 build)

| Delta type | What it tells you | Source | Lifespan | Trust model |
|---|---|---|---|---|
| **Filming** | Block held for a production | 🟢 Open data (NYC film permits) | Hours–days | Authoritative; crowd confirms/corrects |
| **ASP suspended today** | No alternate-side enforcement today | 🟢 Open data (ASP calendar + emergency) | 1 day | Authoritative; crowd confirms |
| **Special event / emergency** | Parade, marathon, snow emergency, fair | 🟢 Open data + crowd | Hours–day | Authoritative + confirm |
| **Construction / street work** | Repaving, Con Ed, scaffold closure | 🟡 Partial open data | Days–months | Hybrid: seed + crowd fills gaps |
| **Sign correction** | "This sign is wrong / contradicts the data" | 🔴 Crowd-only | Long (until DOT/data fix) | Reputation + upvotes |
| **Block notes** | Overnight safety, flooding, double-park norms | 🔴 Crowd-only | Semi-durable | Reputation + upvotes |
| **Enforcement active** | Agent on the block now (neutral framing) | 🔴 Crowd-only | Minutes | Decay + "still there?" |
| **Sweeper passed / coming** | Cleaning truck already came (block's clear) | 🔴 Crowd-only | Mins–hours | Decay + confirm |
| **Broken meter** | Muni-meter down | 🔴 Crowd-only | Until fixed | Confirm |
| **Open spot** | A passerby spotted an empty legal spot | 🔴 Crowd-only | **~2–3 min (shortest of all)** | Claim + "still open / taken" |

**Deferred (not in scope):** spot-**handoff** / "I'm leaving this spot" — an *occupant* transferring the spot they're vacating. High legal + abuse risk (cf. MonkeyParking/Sweetch SF cease-and-desist over monetizing public spots; free coordination is safer but heavily gamed). Deliberate later bet, not core.

> **`open_spot` is distinct from handoff and IS in scope** (Tier 3 experiment — see §5). A *passerby* reporting an empty spot is not an occupant transferring ownership, so it sidesteps the MonkeyParking problem entirely — cleaner legal footing **and** the bigger "WE" play (non-parkers — pedestrians, residents, cyclists — contribute without ever parking, expanding the supply side beyond drivers). It shares handoff's *brutal-staleness* challenge, which makes it the **highest-risk / highest-reward** crowd type.

### Structural pattern

Everything splits on two axes that drive the data model:

- **Source:** 🟢 open-data-seedable → 🟡 hybrid → 🔴 crowd-only
- **Lifespan:** ephemeral (mins) → session (hours/day) → durable (weeks+) → permanent correction

This maps directly onto **how much density each delta needs to be useful** — which is the build order.

---

## 5. Tiered build order (sequenced against cold-start)

Each tier introduces **exactly one new hard primitive**, so we never build three risky systems at once, and value ships at every tier.

### Tier 1 — Seeded, citywide, value at zero users
*Filming · ASP-today · special events · construction-where-data-allows*
- Works **day one, citywide, with nobody else on the app** — the cold-start bridge.
- Authoritative → **needs no reputation system to ship.**
- New primitive: **open-data ingestion** (`@backend-data` lane; new Supabase schema, separate from the unapplied tracker schema).

### Tier 2 — Crowd, durable, low density bar
*Sign corrections · block notes*
- A single contribution **persists and helps everyone** — doesn't expire, so a handful of users add lasting value. Compounds the dataset.
- New primitive: **reputation + upvote** (needed here, not in Tier 1).

### Tier 3 — Crowd, ephemeral, high density bar
*Enforcement active · sweeper passed · broken meter · open-spot (beachhead experiment)*
- Only lights up with enough **simultaneous active reporters** → comes alive in the **beachhead neighborhood first**, not citywide.
- New primitive: **decay + "still there?" confirm.**
- This is where **patrol mode (W8.5e–i)** lands as the reporting UI.
- **`open_spot`** is the most density-dependent of all (useful-life ~2–3 min) → **beachhead-only experiment** (SOHO/LES), not citywide. Mandatory mitigations: **brutal decay** + honest *"spotted ~2 min ago"* framing (never "open spot") + a **"heading there" claim** that dims the pin to reduce races + a **reputation reward** for the non-parker contributor (the motivation engine). Requires a new `open_spot` pin type — a Tier-3 schema enum addition + iOS `CommunityPin` enum migration (the merged enum has the other 10 types; this one's deferred until we build Tier 3).

---

## 6. The "Enforcement active" framing decision

Reporting a uniformed enforcement agent on a public street is **legally protected** (publicly observable info about government agents; cf. Waze vs. NYPD 2015 — Google didn't comply, nothing happened; cf. headlight-flash speed-trap First Amendment cases). The issue is **positioning, not law**, with two real risks:

1. **App Store review** — Apple guideline language on apps that "encourage illegal/reckless behavior." Parking is mild, but "report ticketing agents to avoid tickets" could make a reviewer balk.
2. **City relations** — the city owns the ASP feed, sign data, and ground truth we want. Don't brand the app "dodge the meter maid" and pick a fight with our best data partner.

**Decision — reframe from evasion to compliance:**
- One **neutral pin type: "Enforcement active"** (optional sub-tag), not separate "cop" vs "truck" cartoons.
- Copy is **heads-up / compliance** ("Enforcement active on this block" → prompts *move your car / feed the meter*), never "avoid tickets."
- **Cleaning-truck use leads** in screenshots + App Store copy — it's the civically-clean half (the city *wants* people to move cars before sweeping) and it launders the whole feature.

Same data, different story. The icon + copy + category design is the lever; pull all three.

---

## 6.1 Reactions — the trust engine, not social flavor

The `votes` table + "Still there?" decay in `supabase/02-pins-schema.sql` **is** the Waze interaction layer. Reframe it: reactions are the **trust / verification engine**, not engagement decoration — crowd pins are only as reliable as the confirm loop behind them.

| Pin kind | Reaction (one tap) | Effect |
|---|---|---|
| **Ephemeral** (enforcement, sweeper, broken meter, open-spot) | "Still here" / "Gone" | **Extends or kills the pin's TTL** — the core Waze loop |
| **Durable** (sign correction, block note) | Upvote / downvote | Feeds **reputation**; surfaces good info, buries bad |
| **Any** | Comment (`comment_anchor` type) | Threaded discussion on the pin/block |

**Design rule:** one tap, especially in-car — Waze's genius is the single-thumb "still there" at speed. No emoji palette; a **binary confirm + a reputation reward for confirming** is what keeps the loop alive.

---

## 6.2 Display surfaces — where pins appear

Not everything is a top banner. The top banner (the W7 ASP pattern) is for **zone/citywide states** (ASP-today, snow emergency) where *everyone* is affected. **Block-local pins use a layered, relevance-gated model** instead:

| Surface | When | What the user sees |
|---|---|---|
| **Map marker** (base layer) | Always, while live | Pin on the block; `sub_tag` icon; **opacity fades as it decays**; confirm-count badge; tap → confirm/clear |
| **Push** (W6 infra) | Pin near *your parked car* | "Enforcement near your car on [block] — consider moving it" — the killer reminder for the experienced parker |
| **Drive Mode callout** (bottom-card chip / voice) | Pin on *your route* | "Enforcement active 2 blocks ahead" — the in-car fear→relief moment for the novice |
| **Top banner** | ❌ reserved | Zone-wide deltas only (ASP-today, snow emergency) — enforcement is too local |

Through-line: the **marker is always-on (cheap); alerts fire only when personally relevant** — near your car (push) or on your route (drive callout). That relevance-gating is what stops it being spammy, and it mirrors the two-segment split (parked-car reminder = experienced user; on-route callout = driver/novice). Formal HIG pass on the decay visual + push copy is a `@designer` task in the Tier 3 cycle.

---

## 7. Connection to existing assets

- **PWA already has** a Threat Tracker UI (mock + Supabase-ready provider), zone chat (SOHO/LES Realtime), and a reputation-scoring concept — partial proof, to be brought into the iOS 1.0 framing under this taxonomy.
- **W5 pin-drop** is the existing typed-pin substrate to generalize. **Schema decision to make first:** does the pin model generalize to typed pins (pin-drop / filming / enforcement / sign-fix / comment-anchor / …) or stay pin-drop-only? Getting this right before patrol mode saves a migration.
- **Drive Mode / Park Mode stay central** — community wraps them, does not replace them.

---

## 8. Implication for the queued metrics + survey work

The queued `docs/w8-metrics-survey-spec.md` measures **Drive Mode** fear-reduction (70%-Yes). Under this direction the **north-star broadens** to community health — contribution density, active-reporter coverage, retention — with Drive-Mode fear-reduction as **one input**, not the whole metric. **Recommend holding that tech-lead dispatch** until the success metric is resettled against this doc.

---

## 9. Open questions for `@tech-lead`

1. **Pin schema:** generalize to typed pins now, or migrate later? (Recommend: generalize now — it's foundational to 1.0.)
2. **Reputation model:** pseudonymous identity reuse from the existing `profiles`/zone-chat work, or new?
3. **Beachhead neighborhood:** which one dense zone do we launch Tier 3 in? (PWA already piloted SOHO/LES.)
4. **Tier 1 sources:** confirm which NYC open datasets are reliable enough to seed (film permits ✓; ASP calendar ✓; DOT closures = quality TBD).
5. **North-star metric:** what replaces/extends the 70%-Yes Drive Mode survey for a community-led 1.0?
6. **TF1 scope line:** does TF1 ship Tier 1 only (seeded, citywide, no reputation), with Tier 2/3 as TF2 — or more?

---

*This doc is the product-direction backbone. `@tech-lead` turns Tiers 1–3 into feature specs at `docs/<feature>.md`; `@backend-data` owns Tier 1 ingestion schema; `@ios-engineer` owns pin UI + reporting.*
