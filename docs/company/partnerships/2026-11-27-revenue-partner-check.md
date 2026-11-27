# Revenue partner check (2026-11-27)

Checks the ideas in `docs/product/revenue-concepts-brainstorm.md` against public web sources. Nothing was contacted or signed up for. Most rates below come from third-party listing sites, not the company. Treat them as unverified until we see the company's own terms. Search snippets only; I did not open every page.

## C1 Garage fallback
**Exists? Yes (partly verified).**
- SpotHero: FlexOffers lists 2.4% of sales, 30-day cookie ([FlexOffers](https://www.flexoffers.com/affiliate-programs/spothero-affiliate-program/), [affi.io](https://affi.io/m/spothero)). Unverified: no official SpotHero page states a rate. SpotHero says it tailors deals per partner ([partner page](https://spothero.com/sell-parking)). It also has a developer platform for parking inventory ([developers](https://spothero.com/developers), [VentureBeat](https://venturebeat.com/business/spothero-launches-developer-platform-to-expand-its-parking-inventory-into-third-party-apps)).
- ParkWhiz/Arrive: public v4 API docs, but credentials only for approved partners, no public affiliate terms ([Arrive developer](https://developer.arrive.com/getting_started), [supergood](https://supergood.ai/api-report-card/parkwhiz)). Contact path listed: dev@parkwhiz.com (public).
- JustPark (UK-focused) is on Awin; Parkaro 5-12.5%; ParkCloud "up to 20%" ([JustPark](https://www.justpark.com/affiliates/), [FlexOffers ParkCloud](https://www.flexoffers.com/affiliate-programs/parkcloud-com-affiliate-program/)). Not clear these cover NYC.
- BestParking, Icon: nothing found. Unverified.

**Join difficulty:** Easy for SpotHero via an affiliate network. Harder for API access.
**Math (my estimate):** a $30 garage booking at 2.4% is about $0.72. Tiny per click.
**Verdict:** Real and easy, but pennies per booking. Worth it as a helpful dead-end fix, not as a business.

## B1 Car services
**Exists? Partly.**
- TaskRabbit: on Impact, but listings disagree: $20 per lead, $4-$10 per job, or about 8.57% ([Lasso](https://getlasso.co/affiliate/taskrabbit/), [affi.io](https://affi.io/m/taskrabbit), [LinkClicky](https://linkclicky.com/affiliate-program/taskrabbit/)). Unverified. Check the Impact dashboard.
- Angi: 10% reported on Impact ([LinkClicky](https://linkclicky.com/affiliate-program/angi/)). Handy: $10-$25 per sale, or $25 per new booking, or 5-10% ([Lasso](https://getlasso.co/affiliate/handy/), [FlexOffers](https://www.flexoffers.com/affiliate-programs/handy-affiliate-program/)). All unverified. Neither covers snow or car wash well (my read; not checked).
- Thumbtack and Wag: consumer referral credits only; no publisher program found ([Thumbtack](https://referralcodes.com/shop/thumbtack-referral)).
- NYC snow removal: no referral program found. Mobile car wash: NYC requires a DCWP car wash license ([DCWP fact sheet](https://www.nyc.gov/assets/dca/downloads/pdf/businesses/MobileCarWashFactSheet.pdf)). Waterless operators exist (BuraqWash, Amenify) but no partner terms found.

**Join difficulty:** Easy for networks. For local operators, a direct deal is needed.
**Verdict:** Generic networks pay little for the wrong services. A direct deal with one or two local snow and wash operators is the real route. Slow.

## C2 Auto insurance leads
**Exists? Yes.**
- Rate card (vendor-sourced): auto web leads $2-$12 shared, $8-$16 high quality; live transfers $45-$150; calls $20-$80 ([Phonexa](https://phonexa.com/blog/insurances-leads-cost/)). Other sources say $5-$50 per lead ([ActiveProspect](https://activeprospect.com/blog/insurance-leads-cost/)). Vendors sell leads, so numbers lean high.
- Rules: the FCC one-to-one consent rule was vacated ([Verisk](https://marketing.verisk.com/the-fccs-11-consent-rule-is-vacated-its-time-for-our-industry-to-refocus-on-clear-consumer-consent-and-expectations)), but TCPA consent still matters. New York producer-licensing and referral-fee rules: not found, unverified. Flag for `@legal-compliance`.
- Fit: a parking app has no insurance intent. Expect low conversion (my estimate). Also a privacy-trust risk.

**Join difficulty:** Medium. Networks screen traffic.
**Verdict:** Pays per lead, but poor fit and legal homework. Not soon.

## C3 EV charging
**Exists? Partly.**
- NYC DOT and Con Edison run curbside Level 2 chargers; FLO supplies and runs the network ([DOT release](https://www.nyc.gov/html/dot/html/pr2026/expansion-of-curbside-electric-vehicle-charging.shtml), [evaluation report](https://www.nyc.gov/html/dot/downloads/pdf/curbside-level-2-charging-pilot-evaluation-report.pdf)). Expansion in Manhattan is planned.
- No affiliate program or public data feed found for these. ChargePoint/EVgo/PlugShare: nothing found. Unverified.

**Verdict:** A useful map layer, not revenue. Ask DOT/FLO for location data later.

## B5 Ticket help
**Exists? Yes, as competitors.**
- Fixed charged a $1.95 fee plus a success fee; WinIt takes half the fine if it wins; Ticket Wiper is contingency ([TechCrunch](https://techcrunch.com/2015/05/22/fixeds-app-can-now-fix-your-new-york-parking-tickets), [Ticket Wiper](https://apps.apple.com/us/app/ticket-wiper/id1176103171)). These are older sources; current status unverified.
- The city offers a free official Pay or Dispute app ([NYC DOF](https://www.nyc.gov/site/finance/vehicles/nyc-pay-or-dispute.page)). That caps what people will pay.
- No referral or partner program found for any of them. Unverified.

**Verdict:** Crowded, free city option, no known referral. Could cold-pitch a partnership, but low odds.

## C4 / C5 Reminders and movers
**Exists? Partly.**
- NY DMV already sends free registration and inspection reminders ([DMV](https://dmv.ny.gov/more-info/get-email-and-text-reminders)). No mechanic referral program found. Unverified.
- Movers: lead programs pay roughly $1-$16 per basic lead, up to $50 per completed shipment ([TopMoving](https://www.flexoffers.com/affiliate-programs/topmoving-affiliate-program/), [College Hunks](https://flexoffers.com/affiliate-programs/college-hunks-hauling-junk-moving-affiliate-program), [Auto Movers Choice](https://ui.awin.com/merchant-profile-terms/123716)). Mostly national lead sellers, not NYC movers.

**Verdict:** Low money, weak fit. Skip for now.

## E1 Fleets
**Exists? Yes, and the city already does the discount.**
- DOF's Fleet Program is free. Stipulated Fine (delivery) and Commercial Abatement (other service) give reduced fines in exchange for giving up hearings; commercial plates only; 45 days to respond ([NYC DOF](https://www.nyc.gov/site/finance/vehicles/commercial-fleet-program.page), [rule amendments](https://www.nyc.gov/assets/finance/downloads/pdf/final-rules/rule_amendments_for_the_parking_violations_fleet_program.pdf)). $58.3M paid under Stipulated Fine in FY26 ([2026 report](https://www.nyc.gov/assets/finance/downloads/pdf/26pdf/2026-local-law-6-report.pdf)).
- Existing vendors: Fleetworthy bought Empire Commercial Services, a NYC ticket management firm ([CCJ](https://www.ccjdigital.com/business/mergers-acquisitions/article/15709785/fleetworthy-acquires-parking-violation-management-company)). Geotab has a Ticket Monitor ([Geotab](https://marketplace.geotab.com/solutions/ticket-monitor/)). Pricing: not found.
- Possible gap (my read, not proven): the products fix tickets after they happen. Few prevent them (loading-zone and meter rules at the curb). Small fleets are said to get less flexibility ([rule record](https://www.nyc.gov/assets/finance/downloads/pdf/rules/stip-fine-comments.pdf)). WePark would need commercial-rule data it may not have yet.

**Join difficulty:** Direct sales; no partner program needed.
**Verdict:** Best long-term money, but a real sales effort. Test with a few small fleets.

## F1 Venue partnerships
**Exists? Yes.**
- SpotHero calls itself an official partner of the Arena at Madison Square Garden; NHL.com's Rangers page links to it ([SpotHero MSG](https://spothero.com/destination/nyc/madison-square-garden-parking), [NHL](https://nhl.com/rangers/arena/parking)). Yankee Stadium: listed, but not confirmed official. Lincoln Center: no partner found.

**Verdict:** The big venues are taken by SpotHero. Smaller theaters and venues are open. Slow, low odds.

## Ranked top 5: real money soon for a small app with few users
1. **A1/A3 Pro and Visitor Pass** (not partner-based, but still the surest money; see the brainstorm).
2. **C1 Garage fallback via SpotHero:** easy to join, pennies per booking, but zero cost and helps users.
3. **E1 Fleets:** biggest dollars per customer; a few paying fleets beat thousands of clicks. Needs sales and commercial rule data.
4. **B1 Car services, direct deals with 1-2 NYC snow/wash operators:** better rates than the networks, and tied to real moments of need. Slow to set up.
5. **C5 Movers leads:** easy to join, $1-$16 per lead, low fit. Insurance (C2) ranks just below because of legal and fit risk.

Key unknowns to confirm directly: SpotHero's real rate, TaskRabbit/Angi/Handy rates in their own dashboards, and any NY insurance referral rules (`@legal-compliance`).
