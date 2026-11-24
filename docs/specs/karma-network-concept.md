# Karma, Ranking, Market and the Parking Network (Concept + Research)

**Status:** CONCEPT / RESEARCH. Not a build order. No code, schema applied, or design mocks. Date: 2026-11-23. Owner: Tech Lead.
**Trigger (Kevin, 2026-11-23, verbatim):** "parking is pretty shitty and boring so i would like to make the app fun, interactive and useful ... We will need to understand the karma ranking and market or leaderboard that can be created. Maybe I can ask NYC for money to fund coffee trips or something local if they help their neighbors. Loose idea. just spit balling. Yes circling is a good idea but honestly people are always kind of looking. A good idea though if you have a parking network to advise, circling or be home in 30, so that people can give you their spot if they're planning to leave."
**Builds on (read, not restated):** `docs/nyc-neighbors-incentives-concept.md` (layers, "reward verifiable + durable", legal guardrail section 9), `docs/specs/qr-spot-handoff.md` Rev 2 (section 9 safety, section 10 karma), `docs/design/spot-pass-design.md` (section 2.4 karma buckets, alias system), `docs/regulars-network-spec.md` (the 5-person trust network, already specced), `supabase/03-community-2.0-schema.sql` (reputation ledger).

---

## 0. Needs Kevin first (the vital ones; details in section 12)

1. **Redeemable rewards: yes or no, and when?** Recommendation: points-only through MVP; first redeemable is a *merchant-funded, merchant-redeemed* perk (a "pay-it-forward coffee"), never cash or gift cards, and only after a legal check. Needs your go/no-go on pursuing merchants at all.
2. **Entity.** Government and foundation money (section 7) requires a nonprofit or fiscal sponsor. Stay a for-profit app (then: merchant money, BIDs, one DOT/Community Board relationship) or also stand up a fiscal sponsor?
3. **Pilot neighborhood.** Leaderboards, the network and merchants all need density. Pick one (SoHo/LES is where chat already is).

---

## 1. Problem and user story

Parking is a chore. The Spot Pass makes one moment (a driver leaving, a neighbor waiting) human and fun. This doc asks what turns a single delightful handoff into a *habit and a neighborhood*: a visible reputation (karma), a friendly scoreboard, things karma can do, and a way to ask the neighborhood for help *before* you arrive ("home in 30", "circling now") that ends in a Spot Pass.

User story: "I'm 30 minutes out. I tap 'Home in about 30 near West Village.' A neighbor who is leaving soon sees it and taps 'I'll pass you mine,' and a Spot Pass appears on my phone. Later I see 'You helped 3 neighbors park this month, you're a Block Captain.' My local cafe gave me a free coffee for it."

Why now: Spot Pass C0 scaffold landed (#160); karma and `helped_count` already exist server-side; the design already bucketed karma on the badge. Making karma a *product* is mostly policy and a few columns, not new infrastructure.

---

## 2. Scope

**In (this concept covers):** karma model, ranking/leaderboards, karma "market", the parking network (broadcast and offer), funding/partner research, engagement mechanics, phasing, metrics.

**Out:** code, schema applied (Kevin applies all schema), mocks (a later `@designer` pass), any money movement, any commitment to a government program, and paying people to hold or control a spot (illegal, see `nyc-neighbors-incentives-concept.md` section 9). Every idea below rewards *information and courtesy*, never control of a public spot.

---

## 3. Karma model

### 3.1 What exists today (verified in source)

- `profiles.reputation` int and `helped_count` (`supabase/01-mvp-schema.sql:11`, `03-community-2.0-schema.sql`). Awards are server-side triggers: pin report +5 (`award_report_reputation`, ~line 270), confirm +2 and `helped_count`+1 (`award_confirm_reputation`, ~295), chat +1 (`award_chat_reputation`, ~327), and a first-confirm accuracy bonus.
- `reputation_award_log` is an append-only, deny-all-RLS ledger unique on `(source_table, source_id, kind, subject_id)` with `kind in ('confirm','accuracy')` (lines 238-262). The model is deliberately **one-way** (never revoked) for replay safety (comment at ~226-236).
- Spot Pass section 10 defaults: driver +5 and `helped_count`+1 on seeker "Got it, thanks!"; seeker +1/+2; caps 3 rewarded handoffs/user/day; same pair once per 24 h; ledger key `(handoff_id, role)`.
- Known weak spot, already on the watch-list: two colluding accounts can farm confirm +2 today (`docs/regulars-network-spec.md:876-888`).

### 3.2 Ways to earn, ranked by value to the product (with recommended weight)

Principle: **weight by verifiability x durability x scarcity of the behavior**, per the concept doc's "verifiable + durable" insight. Weights are starting values in the existing integer `reputation` units.

| Rank | Action | Verified by | Weight | Notes |
|---|---|---|---|---|
| 1 | Spot Pass handoff, seeker-confirmed (driver) | Seeker "Got it, thanks!", different user | +5 (exists) | The flagship: a physical, mutual, two-party event. Keep caps. |
| 2 | Closure/restriction report with photo, later confirmed by others | Photo + geo + 2 independent confirms | +8 at confirm threshold (new kind) | Highest-value *data*. Pay on cross-confirmation, not on submit. |
| 3 | Accurate report (existing accuracy bonus) | Confirmed by others | +5 report / accuracy bonus (exists) | Keep; later add a "verified by 2+" tier. |
| 4 | Coverage request fulfilled | Requester marks helpful | +3 | Pairs with coverage requests (PR #139). Paid on requester thanks. |
| 5 | Network offer that becomes a Spot Pass (section 6) | Same seeker confirm as rank 1 | +5, plus +1 "network bonus" | Same event as rank 1, never double counted: one ledger row per `(handoff_id, role)`. |
| 6 | Confirming a pin ("still there?") | Independent voter | +2 (exists), **cap 10/day** | Cheapest to farm; cap it. |
| 7 | Seeker confirming outcome | Own action | +1/+2 (exists) | Rewards closing the loop (data quality), not asking. |
| 8 | Chat message | none | +1 (exists), **cap 5/day, diminishing** | Lowest signal and easiest to inflate; consider zero. |

**Do not reward:** raw "spot open now" posts (fleeting, unverifiable; concept doc section 6), logging in or opening the app, sharing to social (a cosmetic perk, not karma), or inviting users for karma (invite fraud magnet). Invites earn a *thank-you badge* only after the invitee completes a verified handoff.

**Negative events**, carefully: an upheld abuse report **freezes earning for N days**, rather than subtracting points. The ledger is one-way by design and subtraction reopens griefing (see the schema comment). Repeated no-shows feed the hidden trust weight below, not visible karma.

### 3.3 Karma and trust are two numbers

Recommendation: **keep `reputation` as lifetime karma (monotonic, simple, drives tiers) and add a separate hidden `trust` weight** (server-only, 0-1) that scales *new* awards and decides whether a user appears in public rankings. This lets us be generous to honest users and quietly starve farmers without ever visibly "punishing" anyone.

### 3.4 Decay and seasonality

- **Lifetime karma never decays.** Tier names are earned; taking them away feels bad and punishes people for leaving the city for a summer.
- **Leaderboards run on windowed karma** (rolling 30 days, calendar season) so newcomers can win and old accounts cannot coast. Computed from the ledger by `created_at`, not stored per window.
- **Seasons** map to real NYC parking life: the ASP calendar, "Snow Season" (Dec-Mar, when handoffs matter most), and the "Alt-side break" holiday suspensions. Seasonal badges are cosmetic and permanent ("Snow Season '26"), the seasonal board resets.
- **Streaks** are a separate soft counter, never a karma multiplier (section 8).

### 3.5 Anti-gaming (ranked by threat)

| Threat | Control | Cost |
|---|---|---|
| **Collusion pairs / rings** (A and B trade handoffs or confirms) | Existing 24 h pair cooldown, extended to **diminishing weight per distinct counterpart**: first handoff with a given person pays 100%, repeats 50% then 0 within 30 days. Offline ring detection: graph of award edges, flag small dense cliques (as the Regulars watch-list proposes). Exclude Regulars-edge counterparts from *leaderboard* weight (they still earn personal karma). | Server only; one nightly query |
| **Sybil accounts** (many anon accounts from one device) | Clip anon users are cheap by design, so give them **zero leaderboard eligibility until promoted** (full-app account with N verified actions over D days). Device/IP velocity limits; App Attest later if abuse appears. | Policy + threshold |
| **Self-scan / own-pass** | Exists (reject, nonce check). Add timing sanity: a handoff completed in under ~20 s is down-weighted. | Small |
| **Farming volume** | Existing 3/day cap; extend caps to every earn kind (3.2). A daily karma cap per user (suggest 25) so rankings measure *breadth over weeks*. | Policy |
| **Confirm-farming on photos** | Photo EXIF/geo/time checked at capture; confirms must come from users outside the author's Regulars, weighted by trust. | Medium |
| **Griefing via fake reports** | Reports freeze, not subtract; abuse reports against a person need 3 distinct reporters (matches Spot Pass 3-report suspension). | Exists |
| **Paid incentives raise stakes** | Anything redeemable (section 5) is fenced behind a *higher* trust threshold and per-user monthly caps. This is why points-only comes first. | Phasing |

### 3.6 Schema ideas (Kevin applies; none applied here)

Extend the existing ledger rather than building the `reputation_events` ledger that the reconciliation spec deliberately deferred (revisit only if windowed boards get slow).

1. Widen `reputation_award_log.kind` from `('confirm','accuracy')` to add `'handoff_driver'`, `'handoff_seeker'`, `'closure_verified'`, `'coverage_helped'`, `'network_bonus'`. Add `points int not null` (weights can change without rewriting history) and `counterpart_id uuid null` (pair weighting and ring analysis). Index `(subject_id, created_at)` for windowed boards.
2. `profiles`: add `trust real not null default 0.5`, `leaderboard_opt_in boolean not null default true`, `home_square_id text null` (server-coarsened, see section 4), `earn_frozen_until timestamptz null`.
3. A **scheduled function or materialized view** producing top-N per scope and window with the k-anonymity floor applied (4.3), read via an RPC. The ledger stays deny-all and is never exposed.
4. Handoff rows already hold the pair data; only `counterpart_id` is duplicated into the ledger.

---

## 4. Ranking and leaderboards

### 4.1 Scopes, ranked

| Rank | Scope | Verdict |
|---|---|---|
| 1 | **Home "square"** (coarse zone you belong to; about 8-12 blocks, a ~0.5 km cell) | **Primary board.** Small enough for *neighbors*, large enough for k-anonymity. The heart of the fun. |
| 2 | **Neighborhood** (SoHo, Park Slope; reuse chat zone ids) | Second board. Community pride ("Park Slope vs Carroll Gardens"). |
| 3 | **Borough / City** | Show *neighborhood* standings and only the top few opted-in aliases; individual city-scale boards invite gaming and toxicity for little value. |
| 4 | **My block** | **No ranked block board.** Too small (fails k-anonymity, people become identifiable). Show an aggregate instead: "12 neighbors helped on your block this week" (section 8). |

**Home square:** user-chosen, never inferred from the parked-car pin or live location (`address-anchored-parking.md` is explicitly not wired; Spot Pass section 9 item 5). The user picks a neighborhood on a coarse map; the server stores only the cell id. Changeable at most monthly (stops square-hopping to win a small board).

### 4.2 Time windows

Default views: **This week** (resets Monday, fast feedback) and **This season**. All-time exists as personal lifetime karma and tier, *not* a public board (it ossifies). Windows are computed from the ledger.

### 4.3 Privacy (the designer's rationale applied)

The designer bucketed the badge ("Helped 10+") because a persistent exact number on a badge strangers photograph links passes to one person (`spot-pass-design.md` section 2.4, finding F9). The same logic scales up:

- **Boards show alias + glyph and a *tier*, not exact karma, and rank in coarse bands** (podium of top 3 by alias, then "Top 10%", "Top 25%"). Your exact number is visible only to you.
- **The board alias is a stable alias, distinct from the per-pass rotating alias** (pass aliases are deliberately unlinked; if the board alias matched, the scoreboard would deanonymize passes). It is also never the username.
- **Never an exact location.** A board's scope label is the square's *name* ("West Village North"), not a coordinate.
- **k-anonymity floor:** a board renders only with at least 20 eligible, opted-in, active users in the window (suggested); below that, show the neighborhood aggregate and "be the first Block Captain here."
- **Opt-out** is one switch (`leaderboard_opt_in`): you keep earning and keep your tier, you just never appear. Default **on with alias** (default-off kills the feature), disclosed in one plain line at first earn, not a modal. Decision to confirm (section 12).
- Account deletion already cascades via FK; windowed boards need no extra purge.

### 4.4 Tiers and names (NYC-flavored; lifetime karma, tunable)

Replaces the badge bucket labels in-app once confirmed (design finding F13); the Spot Pass badge keeps its bucket labels.

| Tier | Lifetime karma | Name |
|---|---|---|
| 0 | 0 | **New Neighbor** |
| 1 | 5+ | **Stooper** (sits on the stoop, keeps an eye out) |
| 2 | 25+ | **Block Regular** |
| 3 | 75+ | **Block Captain** |
| 4 | 200+ | **Super** (the building super: knows everything, fixes everything) |
| 5 | 500+ | **Borough Legend** (per borough, e.g. "Brooklyn Legend") |

Naming ranked: (1) the above, plain and warm; (2) subway-line colors (fun, but needs a graphic system and invites line rivalry); (3) bodega-cat ladder (cute, but collides with the alias system). Avoid military or competitive words.

### 4.5 Keeping it fun, not toxic

- Celebrate **neighborhood totals** louder than individuals ("Carroll Gardens helped 214 people park this week").
- No loser list, no shown rank drops, no push on being overtaken. Rank is pull-only.
- Seasons reset so a bad month is forgiven; show "personal best" beside rank.
- Cooperative framing: a weekly neighborhood goal with shared progress.
- No speed or volume trophies (nobody should rush a departure or drive unsafely for points).

### 4.6 What top-of-leaderboard actually gets (cheapest first)

(1) Name on the neighborhood **Wall of Thanks** for the week/season; (2) a **permanent seasonal cosmetic glyph tint/badge**; (3) **early access/beta invites**; (4) **a sponsor perk** (merchant-funded, 7.1 A); (5) **a donation in their name** to a neighborhood cause. **No cash prizes, no gift cards in MVP.**

---

## 5. "Market" for karma

### 5.1 What karma could unlock, ranked

| Rank | Use | Type | Verdict |
|---|---|---|---|
| 1 | **Cosmetics** (glyph tints, badge frames, alias packs, seasonal stamps) | In-app | **Do first.** Zero cost and legal exposure; makes the QR "sexy" (Kevin's ask). Earned only, never purchasable, so karma stays pure. |
| 2 | **Network standing** (offers shown first; higher request allowance) | In-app | Natural, but perks widen *capacity* (2 broadcasts/day vs 1), never priority over a neighbor's genuine need. Keep it "visibility", never "reservation" (legal gray area). |
| 3 | **Donate karma** (karma converts into a small sponsor-funded donation to a neighborhood cause) | Charitable | Strong story; sponsors do good without redemption fraud. WePark never holds donor money. |
| 4 | **Merchant perk** ("show this at Cafe X for a free drip") | Local, redeemable | The coffee idea. **Merchant-issued, merchant-redeemed, in person** (5.3). First redeemable. |
| 5 | **Early access / TestFlight cohort** | In-app | Free; good for Super/Legend tiers. |
| 6 | **Gift cards / cash / a generalized "WePark dollars"** | Redeemable | **Not recommended** (5.2). |

### 5.2 Points-only vs redeemable (legal / App Store / tax)

*Not legal advice. Get a one-hour consult with a New York attorney before any redeemable launch.*

- **Apple 3.1.1.** Credits redeemable for *digital* goods must use In-App Purchase; App Review has rejected apps letting users redeem in-game currency for gift cards usable on other platforms (indicative from developer-forum threads; verify against the current Guidelines). A **physical, in-person, local good** is outside IAP, which is why the in-person perk is the safe shape. We sell nothing, so no commission question arises.
- **Apple 5.3 (gaming, gambling, lotteries).** Sweepstakes and contests must be developer-sponsored, show official rules in-app and state Apple is not a sponsor. A *random draw* among top karma is a sweepstakes; avoid it by making rewards **deterministic and earned** (threshold reached = perk). No raffles.
- **New York game-of-chance law.** GBL 369-e requires registration and a bond when a chance-based game offering over $5,000 in prizes promotes products or services (NY Dept. of State). Deterministic perks sidestep it entirely.
- **Tax.** Merchant-funded coffees are tiny in-kind gifts and WePark pays no one. If WePark ever pays cash or gift-card value, expect W-9 collection and 1099 reporting above the IRS threshold (confirm the current figure with an accountant), a heavy burden for an indie app. Another reason merchants, not WePark, hold redemption.
- **City money.** Do not ask City agencies to fund *prizes to individuals*; ask them to fund *programs via a nonprofit* (section 7).
- **Parking-sale line.** Cities have gone after apps that sell or reserve public spots (MonkeyParking, per the concept doc). Money-linked features must reward *information or neighborliness*, never a spot. Keep "courtesy, not a promise" language in the network.
- **Fraud.** Redeemables multiply every threat in 3.5. Controls: trust-gated eligibility, one perk per merchant per user per month, in-person redemption at the counter (staff see a human and act as the fraud screen), no transfer.

**Recommendation:** points-only through MVP. First redeemable = **one merchant, one neighborhood, in person, deterministic**, launched only after a season of boards with no ring flags.

### 5.3 Marketplace shape (if/when)

A small **"Neighborhood Perks"** card: sponsor, perk, tier required, where. Not a store, not a currency. Redemption: a full-screen timestamped card with a live-changing element for staff (defeats screenshots). Shown by home square, never by live location.

---

## 6. The Parking Network ("home in 30", "circling")

### 6.1 Reframe

Kevin's insight: asking "is there a spot?" is a weak prompt (people are already looking). The valuable signal is **demand intent answered by supply intent**: *"I arrive around 6:40 near X; if you're leaving around then, pass me your spot."* That is a **broadcast of intent**, answered by **offers**, closing into a **Spot Pass**. Spot Pass today is face-to-face; the network is its **remote front door** for the same mechanic.

### 6.2 Core objects

- **Intent** (the ask): `{kind: home_in | circling, window: about 15/30/45 min, area: coarse square, created_at, expires}`. `home_in` carries an arrival window; `circling` is "now, nearby" and expires in 15 min. The area is a home or destination **square**, never GPS. Times are rounded, matching Spot Pass's "about N min".
- **Offer** (the answer): a neighbor with an **armed leaving plan** (the Spot Pass driver-side "leaving in about 30 min") or a Regulars scheduled departure taps **"Offer my spot."** The server pairs offer to intent and mints a **Spot Pass** for the asker; the alias/glyph handshake proceeds as today. Because it reuses the armed-departure plumbing, the leaver's exposure equals Spot Pass today (one bit plus a window).

### 6.3 Who is in "your network" (recommended order)

1. **Your Regulars** (up to 5; mutual, in-person QR add; `docs/regulars-network-spec.md`): highest trust, notified first, using the existing head-start behavior.
2. **Home-square members who opted in** to "tell me when a neighbor needs a spot" (default off). The scalable pool and the only one that works for strangers.
3. **Anyone nearby via live location**: **not in MVP**; it needs location broadcast or background location, against Spot Pass section 9.

### 6.4 Discovery

- **Asker:** from the goal-first flow, a chip "Ask the neighborhood" (never during active turn-by-turn; 6.8).
- **Leaver:** a quiet in-app row when they have an armed plan: "A neighbor near here may need a spot around 6:40. Offer yours?" Opt-in per offer, always.
- No public feed or map of requests. Only matched, opted-in people ever see an intent, and only as "a neighbor" with a rotating alias.

### 6.5 Matching (deterministic, server-side)

1. **Time:** the intent window overlaps the leaver's own stated leave window (cap 4 h as in Spot Pass).
2. **Distance:** same or adjacent **square** (coarse cell compare; no coordinates exchanged).
3. **Side-of-street legality:** the leaver's *own device* checks, using the existing rules engine (Smart Move logic), that the spot will be legal and ASP-clean for roughly the next 2 h, and only then enables "Offer." The asker never learns block or side; the exact spot is revealed only at the physical, face-to-face handoff as today.
4. **Tie-break:** earliest ask first; one open offer per leaver; an offer expires when the leaver departs.

### 6.6 Notification budget and anti-spam

- Opt-in, default **off**.
- Per recipient: max **2 network pushes/day**, 1 per 4 h, quiet hours 10pm-7am; `interruptionLevel = .passive` for general square pings, `.active` only for a direct offer to the asker.
- Only notify recipients with an **armed leave plan or a recent leaving pattern**; never blast the square.
- Asker: 2 intents/day, one open at a time, silent cancel. Unanswered intents expire quietly ("nobody helped you" is never sent).

### 6.7 Safety (Spot Pass section 9 reused)

- No live location sharing. Intents carry a square and a rounded window only.
- The leaver sees only alias + glyph and a rounded arrival window.
- Same controls: per-offer opt-in, silent cancel, token hash at rest, 3-report suspension, kill switch (`NETWORK_ENABLED`), per-account rate limits, no identity exchange, no address in payloads.
- **New broadcast risk:** "home in 30" implies "this person will be near home then." Mitigate with a square (not a block), rounded time, visibility only to opted-in neighbors and Regulars, and **no persistence past expiry** (purge within 24 h like handoffs).
- **Harassment:** mute a neighbor; report an alias; repeated no-shows lower hidden trust (not karma).

### 6.8 Fit with drive mode and goal-first

- **Drive mode is never distracted:** no network UI, notification, sound or voice while turn-by-turn is active; a pending offer is held until arrival or a stop.
- **Goal-first:** the destination is the goal. At **about 30 minutes out** (known from the ETA the user already sees) the pre-arrival card can show one chip, "Ask neighbors near <area>", tap-to-send, no typing. That is a precise, useful, non-nagging moment for "home in 30."
- Siri/Shortcut "Ask neighbors for a spot" is a later add.

### 6.9 Cold start

- **Useful with zero neighbors:** an intent still yields a Spot Pass the seeker can show a walking stranger, so the network is additive, never a prerequisite.
- **Density gate:** the toggle reads "turns on when 10 neighbors in your area join" with an honest live count (also an invite hook).
- **Seed:** Regulars works with 2 users. Pair with the concept doc's doorman/barista seeding (section 8 there) in the pilot square.
- **Never simulate neighbors or fake activity.**

### 6.10 Recommended MVP (Network v0)

1. **Regulars-only "Home in about 30"**: reuse the Regulars graph and push pipeline; offers from Regulars with an armed plan produce a Spot Pass. Smallest and safest, works with 2 users.
2. **Home-square opt-in pool** behind a flag, enabled only in the pilot square once it has enough members.
3. **"Circling now"** as a 15-min variant, off by default and lowest priority (Kevin himself noted people are always looking anyway).

Defer: request map, anyone-nearby discovery, voice, group asks, any lock-screen surface beyond the Spot Pass Live Activity.

---

## 7. Local rewards and funding research

Headline: **government money is slow, restricted to nonprofits and not shaped like "prizes for neighbors." Merchant money is faster, matches the foot-traffic motive and is the right first move.** Research done 2026-11-23 via web search; verify deadlines and current status on each page.

### 7.1 Avenues, ranked by realistic fit

**A. Merchant-sponsored perks (first; weeks to months).**
- What: a cafe, bakery or bodega funds an in-person perk; it gets foot traffic, a "Good Neighbor of <neighborhood>" halo and a neighborhood-targeted audience (concept doc section 5).
- Odds: **High** for 1-3 shops in a pilot square if framed as a loyalty channel that costs nothing until redemption.
- Who: owner-operators of cafes near active chat/handoff areas; doorman/barista seeding per the concept doc.
- Timeline: 2-6 weeks to a first yes if hand-delivered. WePark holds no money; sponsor pays a flat monthly fee or per redemption (open in the concept doc).

**B. Business Improvement Districts (strong; 1-3 months).**
- What: BIDs are assessment-funded nonprofits running supplemental services, marketing and events for a commercial corridor. NYC had 76 in FY25, 27 of them in Manhattan ([SBS FY25 BID Trends Report](https://www.nyc.gov/assets/sbs/downloads/pdf/neighborhoods/fy25-bid-trends-report.pdf); [SBS BID Directory](https://www.nyc.gov/site/sbs/neighborhoods/bid-directory.page)).
- Fit: one BID can bring many merchants at once ("a coffee on 23rd St for neighbors who helped") and has marketing budget and calendars (holiday shopping). It pays for marketing, so WePark's for-profit status is not a blocker.
- Odds: **Medium.** They want measurable foot traffic; offer redemption counts per block.
- Who: the BID executive director or marketing/program manager.
- Timeline: first meeting 2-4 weeks; pilot decision aligned to their fiscal year. BIDs are also the door to DOT (C).

**C. NYC DOT Smart Curbs / curb management (relationship and data, not cash; 3-12 months).**
- What: Smart Curbs, announced September 2023 under the Curb Management Action Plan, reviews curb rules, gathers community needs and tests curb technology with BIDs and community partners, starting with the Columbus Avenue BID on the Upper West Side ([DOT Smart Curbs launch](https://www.nyc.gov/html/dot/html/pr2024/smart-curbs-program-launch.shtml); [project overview](https://nycdotprojects.info/project/1810/overview); [Curb Management Action Plan](https://www.nyc.gov/html/dot/downloads/pdf/curb-management-action-plan.pdf)). A federal SMART-grant document describes a Curbs API on NYC Open Data; whether it is tied to this pilot is unconfirmed.
- Fit: WePark generates *human-verified* curb signals (closures, ASP exceptions, aggregated handoff counts per square). Pilot vendor work has run through funded programs (e.g., MTA Transit Tech Lab), so a **no-cost data and community-engagement pilot** is the realistic entry, not a grant.
- Odds: **Low-medium** for money; **medium** for a letter of support or pilot invitation if you arrive with a BID.
- Who: the DOT curb management / Smart Curbs team (contacts on the project page) and the Open Data team.
- Timeline: slow; treat as a 2027 relationship.

**D. NYC Small Business Services grants (indirect; 3-9 months).**
- What: [Neighborhood 360 Grants](https://nyc.gov/site/sbs/neighborhoods/neighborhood-360-grants.page) fund *nonprofits* to address Commercial District Needs Assessment findings. SBS announced $5.3M for local nonprofits and BIDs in February 2025 ([release](https://www.nyc.gov/site/sbs/about/pr20250225-neighborhoodgrants.page)); an August 2024 round included marketing for local small businesses ([release](https://www.nyc.gov/site/sbs/about/pr20240806-nddgrants.page)).
- Fit: **WePark cannot apply** (for-profit). A BID or neighborhood nonprofit could write a "neighbors help neighbors, shop local" element with WePark as the tool. No program literally named "shop local" was found.
- Odds: **Low** as a primary plan; a BID could use it as its own line item.

**E. City Council discretionary funding and Participatory Budgeting (long shot; 6-18 months).**
- What: Council expense funding goes only to registered nonprofits, is not a grant, requires Charities Bureau registration, an EIN and internal vetting, and has a roughly six-week application window each January with no late applications ([FY2027 Policies and Procedures](https://council.nyc.gov/budget/wp-content/uploads/sites/54/2026/01/FY2027-Discretionary-Funding-Policies-Procedures-Final-V4.pdf); [NYC Nonprofits guide](https://www.nyc.gov/site/nonprofits/resources/city-council-discretionary-funding.page)). Council Participatory Budgeting has run since 2011 ([Council PB](https://council.nyc.gov/pb/)); the Civic Engagement Commission's citywide "The People's Money" opened its fifth cycle on October 15 with $4 million to propose how to spend ([CEC release](https://www.nyc.gov/site/civicengagement/news/cec-launches-fifth-cycle-of-citywide-participatory-budgeting.page)).
- Fit: a **partner nonprofit** (not WePark) could ask its Council Member for a "neighbors helping neighbors park and shop local" program using WePark as the tool. PB capital funds favor physical projects.
- Odds: **Low for WePark directly; low-medium via a partner nonprofit.** The next expense window opens about January 2027.
- Who: your Council Member's budget/community liaison; the partner nonprofit's executive director.

**F. Civic tech grants and foundations (slow, uncertain).**
- Found: Knight Foundation civic-tech giving has centered on Code for America and city data/engagement work (a 2019 open call spanned 26 metros; NYC not named in the result) ([Knight](https://knightfoundation.org/press/releases/knight-foundation-invests-over-4-million-to-leverage-data-and-tech-to-strengthen-civic-engagement-in-u-s-cities-%EF%BF%BC)); Ford funded Civic Hall Labs for the NYC civic tech community ([Ford](https://www.fordfoundation.org/work/our-grants/awarded-grants/grants-database/civic-hall-labs-inc-136880)); Sloan has supported BetaNYC. I could **not** confirm a current open program at Mozilla or Brooklyn Community Foundation.
- Fit: weak for a for-profit consumer app; plausible via a nonprofit civic-tech host (Civic Hall, BetaNYC, a Code for America Brigade), which also brings volunteers and credibility. Odds: **Low.** Worth a warm intro, not a grant-writing project.

**G. Community Boards (no money, high leverage).**
- Each board's transportation committee is where curb and parking concerns land, with neighbors, BIDs and the Council Member's office in one room. A 10-minute courtesy-angle demo is the cheapest way to earn endorsements and intros. Odds of money: none; of introductions: **high.** Who: the board manager and transportation committee chair; timeline: the next monthly meeting.

### 7.2 Top three to pursue, in order

1. **One to three pilot merchants plus the local BID** (A+B): fastest, aligned incentives, real redemption data.
2. **NYC DOT Smart Curbs team via the BID or a Community Board** (C): a data and engagement pilot and a credibility asset, not cash.
3. **A nonprofit partner (Civic Hall or a neighborhood group) as fiscal sponsor** for a Council/foundation ask (E+F), a 2027 January-window bet.

### 7.3 Draft pitch (merchant/BID version; Kevin edit freely)

> Hi <Name>, I'm Kevin, a <neighborhood> neighbor building WePark, a free NYC street-parking app. Our "Spot Pass" lets a driver who's leaving hand their spot to a neighbor who's waiting, and neighbors who help each other earn Good Neighbor karma. We'd love <Cafe/BID> to be the neighborhood's first Good Neighbor sponsor: neighbors who reach a milestone get a free coffee (or a discount) at your shop, you pay only when a coffee is redeemed, and you get a "Good Neighbor of <neighborhood>" feature in the app plus a count of every redemption so you can see the foot traffic. No cost to try, no contract, a one-month pilot in one square. Could I buy you a coffee and show you a 3-minute demo this week?

Government-facing variant (Community Board or DOT): replace the offer with "anonymous, aggregated block-level counts of neighbor-to-neighbor handoffs and verified curb closures, shared as open data to help the city understand real curb use," and ask for a letter of support or a 15-minute intro to the curb management team.

---

## 8. Fun and engagement

Ranked by impact versus effort. Guardrails: no dark patterns (no fake scarcity, no streaks that punish a missed day, no guilt copy), at most one non-essential nudge per day, **nothing in drive mode**, and every nudge has an obvious "stop these" in the same surface.

| Rank | Idea | Impact | Effort | Notes |
|---|---|---|---|---|
| 1 | **Spot Pass celebration and karma receipt** | Very high | In existing spec | The emotional spine; invest in polish. |
| 2 | **Social proof counters** ("12 neighbors helped on your block this week") | High | Low | Aggregate only, k-anonymity floor; shows the network exists. Replaces a ranked block board. |
| 3 | **Neighborhood weekly goal** (cooperative progress bar) | High | Low-med | Shared, weekly reset, no individual shaming. |
| 4 | **Seasonal events**: ASP holiday suspensions ("Alt-side break: thank a neighbor"), **Snow Season** visibility for handoffs and closure reports, street-cleaning day prompts | Med-high | Medium | Hooks off the ASP calendar already in the app; tied to real parking life. |
| 5 | **Shareable "I passed a spot" card** (token-free, after an outcome; designer F10) | Medium | Low | Growth loop; never share a live QR. |
| 6 | **Soft streaks** ("3 weeks in a row you helped someone") | Medium | Low | Weeks, not days; a missed week is a quiet pause. Cosmetic reward only. |
| 7 | **Neighborhood challenges** (Carroll Gardens vs Park Slope) | Medium | Medium | Needs density first. |
| 8 | **One-tap thank-you notes** from seeker to driver | Medium | Low | Positive only, consistent with Spot Pass section 9 item 14. |
| 9 | Photo "closure of the week" gallery | Low-med | Medium | Moderation burden; later. |

**Rejected:** daily login streaks, "you were just passed" pushes, countdown scarcity on perks, speed bonuses, any prompt while driving.

---

## 9. Architecture and work streams

Touches iOS and Backend. The PWA stays in maintenance (no PWA streams).

| Stream | Owner | Parallel? | Depends on |
|---|---|---|---|
| K1: ledger widening, trust/opt-in/home-square columns, windowed board RPC with k-anonymity floor (migration file; Kevin applies) | `@backend-data` | yes | Spot Pass backend (karma kinds) |
| K2: tiers, personal karma screen, board UI, opt-out, home square picker | `@ios-engineer` | yes, against a mock RPC | K1 contract only |
| K3: board and tier visuals, Wall of Thanks, perk card | `@designer` | yes | none |
| N1: intent/offer tables, matching RPC, push kinds, rate limits, kill switch | `@backend-data` | yes | Spot Pass handoff tables, Regulars graph |
| N2: Ask/Offer UI, pre-arrival chip, offer-to-pass flow, settings | `@ios-engineer` | serial after N1 contract; parallel on mock | Spot Pass C1/C2, Regulars |
| P1: merchant outreach, legal consult, perk copy | Kevin | yes | none |

Contracts to fix up front so streams do not block: board RPC rows (alias, glyph, tier, band; never ids or exact karma), `intent`/`offer` payloads (square id and rounded window only), push kinds `network_ask`/`network_offer`.

---

## 10. Phasing and metrics

- **Phase A (needs only Spot Pass):** tiers and personal karma screen; widened ledger kinds (handoff, closure_verified); daily caps; cosmetics; social-proof counters; opt-out and trust column.
- **Phase B:** Regulars-only "Home in about 30" and offers that mint Spot Passes; weekly neighborhood goal; home squares; square and neighborhood boards behind the k-anonymity floor. Depends on Spot Pass C1/C2 and Regulars.
- **Phase C:** home-square opt-in pool; seasonal events and badges; one merchant perk in one neighborhood after legal consult; donation pool.
- **Phase D (only if C is healthy):** BID-wide perks, aggregated open-data pilot with DOT, neighborhood challenges, nonprofit-partnered funding.

**Metrics that say it is working:**
- Handoffs per 100 weekly actives and **offer-to-"Got it, thanks!" completion rate**.
- Share of handoffs via the network vs in-person QR (does the network add supply?).
- **Time to first offer** after an intent (target median under 15 min in the pilot square).
- **Week-4 retention** of users who earned karma vs those who did not.
- Notification health: network opt-out under 10 percent, no spike in mutes.
- Integrity: ring-flag rate, share of karma held by the top 1 percent (concentration), reports per 1,000 handoffs.
- Local: perk redemptions per merchant per month, new vs returning customers (merchant-reported).

---

## 11. Acceptance criteria (first buildable slice, Phase A)

- [ ] `reputation_award_log` accepts the new kinds without breaking existing `confirm`/`accuracy` uniqueness; replaying any award is idempotent.
- [ ] No board renders for a scope below the k-anonymity floor of eligible opted-in users; rendered rows contain alias, glyph, tier and band only, never `user_id`, username, exact karma or a coordinate.
- [ ] Opted-out users never appear on any board and still accrue karma; the toggle takes effect on the next fetch.
- [ ] Clip/anon accounts are not leaderboard-eligible until promoted per policy.
- [ ] Daily karma cap and per-counterpart diminishing weight are enforced server-side (a test with two colluding accounts shows the payout shrinking).
- [ ] The board alias differs from the per-pass rotating alias and the username.
- [ ] No karma or network UI appears while turn-by-turn is active.
- [ ] No redeemable reward ships in Phase A; any later one requires recorded legal sign-off.

Network acceptance criteria belong in the Phase B spec once Kevin confirms scope.

---

## 12. Open questions for Kevin (the vital ones)

1. **Redeemable rewards at all?** Recommended: not before a clean season of points; first redeemable is a merchant-funded in-person perk. OK to pursue one pilot merchant, and OK to book a one-hour NY attorney consult first?
2. **Entity:** stay for-profit and use merchants, BID and DOT-as-partner only, or also set up or borrow a fiscal sponsor so the Council/foundation avenues open (next Council window about January 2027)?
3. **Leaderboard default:** on-with-alias with opt-out (recommended, more fun) or opt-in (safer, emptier)?
4. **Pilot square:** SoHo/LES (chat exists), or somewhere you personally know a cafe owner or BID director?
5. **Network v0 scope:** Regulars-only "Home in about 30" first (recommended); the home-square pool as a later flag. Confirm "circling now" can wait.

---

## 13. Out-of-scope follow-ups (punted, with rationale)

- **Per-block ranked board:** fails k-anonymity and identifies individuals; use aggregates.
- **Anyone-nearby / live-location matching:** contradicts the no-live-location rule.
- **Cash, gift cards, a WePark-wide currency:** IAP 3.1.1, 1099 and fraud costs outweigh the benefit at this scale.
- **Raffles for top users:** NY games-of-chance registration and Apple 5.3; use deterministic thresholds.
- **`merge_anon_identity` RPC** (Spot Pass Phase 2): matters more once karma has board stakes; schedule before boards open to clip users.
- **App Attest / device integrity:** add only if sybil abuse shows in the ring-flag metric.
- **PWA parity:** none; iOS only.

## Sources (web search 2026-11-23; verify before relying)

- NYC Council FY2027 Discretionary Funding Policies and Procedures: https://council.nyc.gov/budget/wp-content/uploads/sites/54/2026/01/FY2027-Discretionary-Funding-Policies-Procedures-Final-V4.pdf
- NYC Nonprofits, Council discretionary funding: https://www.nyc.gov/site/nonprofits/resources/city-council-discretionary-funding.page
- NYC Council Participatory Budgeting: https://council.nyc.gov/pb/
- Civic Engagement Commission, People's Money cycle 5: https://www.nyc.gov/site/civicengagement/news/cec-launches-fifth-cycle-of-citywide-participatory-budgeting.page
- NYC DOT Smart Curbs: https://www.nyc.gov/html/dot/html/pr2024/smart-curbs-program-launch.shtml ; https://nycdotprojects.info/project/1810/overview ; https://www.nyc.gov/html/dot/downloads/pdf/curb-management-action-plan.pdf
- SBS Neighborhood 360: https://nyc.gov/site/sbs/neighborhoods/neighborhood-360-grants.page ; https://www.nyc.gov/site/sbs/about/pr20250225-neighborhoodgrants.page ; https://www.nyc.gov/site/sbs/about/pr20240806-nddgrants.page
- SBS BID Trends FY25 and directory: https://www.nyc.gov/assets/sbs/downloads/pdf/neighborhoods/fy25-bid-trends-report.pdf ; https://www.nyc.gov/site/sbs/neighborhoods/bid-directory.page
- Ford / Civic Hall Labs: https://www.fordfoundation.org/work/our-grants/awarded-grants/grants-database/civic-hall-labs-inc-136880
- Apple App Review Guidelines (3.1.1, 5.3): https://developer.apple.com/app-store/review/guidelines/ (forum threads on gift-card redemption and sweepstakes are indicative only)
- NY Dept. of State Games of Chance: https://dos.ny.gov/games-chance-registration ; GBL 369-e: https://www.nysenate.gov/legislation/laws/GBS/369-E

---

## Kevin's decisions (2026-11-23)

1. **Redeemable reward: YES, eventually.** A merchant-funded perk redeemed in person ("absolutely, that would be great"). The sequencing still holds: one clean season of points-only karma, plus a one-hour consult with a NY attorney before the first redeemable perk.
2. **For-profit vs fiscal sponsor: UNDECIDED.** Don't build anything that depends on Council or foundation money. Revisit before the ~January 2027 Council window.
3. **Leaderboards: on by default, shown under the alias, with a one-switch opt-out.**
4. **Pilot square: Kevin's own home neighborhood.** Recruiting cafe owners comes later, so the pilot starts points-only and cosmetic, with no merchant perk.
5. **Network v0: Regulars-only "home in ~30", as recommended.** Kevin wants the scaling path designed now, not left implicit. Before building B, the spec has to cover how the network grows past Regulars:
   - the opt-in home-square pool;
   - matching load and notification budgets at 100, 1k and 10k active users per square;
   - cold-start vs dense-area behaviour;
   - the server-side cost of intents and offers.
