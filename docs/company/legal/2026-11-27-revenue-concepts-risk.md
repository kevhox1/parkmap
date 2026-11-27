# Revenue concepts: legal and App Store risk check

**2026-11-27. I am not a lawyer and this is not legal advice.** This is a first pass from public sources and my own knowledge. Statute details marked "verify" I could not confirm. Anything rated Yellow or Red needs a real NY attorney before launch.

## The big three

**A2 Ticket Guarantee: Yellow (lawyer needed before launch)**
- NY Insurance Law defines an insurance contract as a promise to pay money on a fortuitous (chance) event that harms the customer (Ins. Law 1101(a), verify). "Pay your ticket if you parked on green" looks like that. Selling it without a license is a violation (Ins. Law 1102, verify). DFS is the regulator.
- The saving grace: a ticket caused by our own wrong data is not chance. It is our product failing. Sellers who guarantee their own service are usually treated as offering a warranty, not insurance. TurboTax's accuracy guarantee (it pays penalties caused by its own error) is the usual example.
- Lowest-risk structure:
  1. Call it a **"Green Accuracy Promise"**, not coverage or protection. Never say "insurance" or "covered".
  2. Pay only when **our map was wrong**: car pin on green, timestamp proves it, sign data was wrong. Not for anything the driver caused.
  3. Pay as a **refund or credit**, WePark's own money, no third party.
  4. **Cap it**: small amount per ticket, a few per year (numbers for Kevin and lawyer to pick).
  5. Bundle into Pro, no separate premium, no separate price. A separate $7.99 "guarantee tier" looks much more like a premium.
  6. Written terms: needs a photo of the sign, and our sign-wins rule stays. Fix the tension in the copy: the promise is about **our error**, not about the sign.
- Lawyer: yes. Ask for a written view that it is a warranty. Estimate $1,500-$5,000 (estimate). Also check that a ticket refund is not against public policy (verify).
- Apple: it rides on the Pro subscription, so IAP applies (3.1.1). Payouts to users are fine as store credit or by other means, and are not IAP.

**B4 Spot Pass tips: Red**
- What happened: in June 2014 SF's City Attorney sent cease-and-desist letters to MonkeyParking, ParkModo and Sweetch. The city's position was that selling or leasing a public street space breaks the Police Code, with a $300 penalty per sale that could reach users too. MonkeyParking and ParkModo switched off in SF. Sources: [CBS](https://www.cbsnews.com/sanfrancisco/news/san-francisco-clamps-down-on-monkey-parking-app-that-allows-drivers-to-auction-public-parking-spots/), [ParkModo letter](https://sfcityattorney.org/wp-content/uploads/2015/07/S.F.-City-Attorney-letter-to-ParkModo.pdf), [KQED](https://ww2.kqed.org/news/2014/07/10/money-parking-disables-service/). Haystack and Boston reaction: I did not verify; check before citing.
- Those were SF rules. I did not find a NYC or NYS rule that names this exactly, and **I can't say NYC is safe**. NYC could use its Administrative Code or traffic rules (verify).
- Is a voluntary tip different? A little, but weakly. MonkeyParking argued it only shared information and lost that argument in practice. A tip paid because someone vacated a spot, collected and fee-skimmed by us, looks like payment for a spot. Apple also dislikes payments tied to something illegal (Guideline 1.1 and 5.x general legality).
- Fix: do not do it. Free Spot Pass handoffs stay free. If Kevin wants "thank-yous", use non-cash reputation badges.
- Lawyer: yes if ever revisited.

**B1 and B2 car services and car mover: Yellow (B1), Red for now (B2)**
- Worker classification: NY uses a control test. Setting prices, schedules and methods makes workers look like employees. Platform drivers and "dig-out guys" as 1099 is a real risk (NY DOL, Labor Law; the gig-worker rulings, verify). Needs a lawyer.
- Liability: damage to cars, injury, theft, keys. B2 means moving a customer's car on public streets. We would need commercial auto and garage-keepers insurance, driver background checks, and very careful terms. Moving someone's car also touches NYC rules on garages and parking (NYC Admin Code Title 20 licensing, verify). Referral-only with a vetted third-party partner (WePark just introduces, the partner holds the insurance and licenses) is far lower risk. Marking up 20-25% makes us look like the seller and takes on the liability.
- B1: Yellow if referral-only. B2: Red until a partner with licenses and insurance exists.
- Apple: **3.1.3(e)** says goods and services delivered outside the app (physical services) must use payment methods other than IAP. So B1 and B2 must not use IAP. Do not link people out to buy digital things.
- Lawyer: yes before either launches. $2,000-$7,500 (estimate).

**B5 ticket help: Yellow**
- NYC parking tickets go through the Department of Finance / OATH. People may use a non-lawyer **registered representative** (OATH rules, registration required unless family). See [OATH registered representatives](https://www.nyc.gov/site/oath/hearings/registered-representatives.page) and [OATH appearance rules](https://rules.cityofnewyork.us/?p=33569). I did not find a fee or any contingency-fee rule; check. Taking a share of reduced fines is a contingency fee, which attorneys may take only within NY Rules of Professional Conduct (Rule 1.5) and non-lawyers could trip "unauthorized practice of law" (Judiciary Law 478, verify).
- Fix: a **"Contest this ticket" button** that exports our evidence and links to the city's own free process (and the Parking Summons Advocate). Flat fee or referral to a licensed attorney or registered representative, no percentage of fines. Don't promise outcomes.
- Lawyer: yes before any fee. Free version: no.

## Privacy-driven ideas

**D3 "Parked near" offers: Yellow**
- Today's policy says we don't use data for advertising and that continuous location stays on the phone. A location-triggered offer needs: opt-in consent, a clear explanation, the check done on the device, and the redemption data minimized. If the business learns where the user parked, or we log it, that is a new data use.
- Policy changes: new "Offers" section, remove or reword "no advertising" lines, say what a business sees (nothing identifying, only a redemption), update the Apple privacy label (add Advertising or Product Personalization, Purchases if relevant), and keep tracking "No". Check ATT (App Tracking Transparency) is not triggered: it is if data is linked with third-party data for ads.
- Rules: NY has no comprehensive privacy law yet (verify, bills pending); FTC Act section 5 (deceptive claims about data); CCPA/CPRA and similar state laws if non-NY users; NY precise-geolocation proposals (verify). Apple 5.1.1, 5.1.2.
- Lawyer: a short review of the policy wording ($500-$1,500, estimate).

**E5 Insurance data: Red for now**
- Overnight parking location is sensitive precise-location data. Selling or sharing it, even aggregated, conflicts with the current "we do not sell your data" promise, and Apple's rule against sharing user location with third parties without consent (5.1.2). "Sale" is also broadly defined in some state laws; the FTC has acted against location data sellers (e.g., X-Mode, InMarket, 2024, verify).
- Fix if ever pursued: separate explicit opt-in, truly aggregated and coarse data, new policy, new label. The FCRA applies if the data is used to decide insurance eligibility or price (verify).
- Lawyer: yes, always.

## The rest

| Idea | Rating | Main issue and fix | Lawyer? |
|---|---|---|---|
| A1 Pro | Green | Subscription via IAP (3.1.1). Show price and renewal terms plainly, add Restore Purchases. | No |
| A3 Visitor Pass | Green | Consumable or non-renewing IAP. Never imply it works outside Manhattan. | No |
| A4 Household | Yellow | Plain IAP if only app features. Family Sharing is the simple route. Shared cars means two people's data: check pins stay private. | Light |
| A5 Employer seats | Yellow | Enterprise sales outside IAP are allowed only for bulk or B2B (3.1.3(c) enterprise services, verify). Contract and privacy terms. | Yes, contract template |
| B3 Private spot rentals | Yellow | Host liability, local rules, zoning, and taxes. "Never show a fake spot": must be bookable and real. Physical-space rentals use non-IAP payments (3.1.3(e)). | Yes |
| B6 Tow helper | Green/Yellow | Information and directions are low risk. Fees for "recovery" help may be unlicensed agent work. Keep it informational or a referral. | Only if paid |
| C1 Garage fallback | Green | Affiliate links need FTC disclosure ("we earn a fee", [16 CFR Part 255](https://www.ecfr.gov/current/title-16/part-255)). Show only real, priced garages. Pay on the garage's site (3.1.3(e)). | No |
| C2 Insurance leads | Yellow | Lead-gen for insurance may need NY producer license rules (verify); lead data sharing triggers privacy changes. Use a licensed partner's own form. | Yes |
| C3 EV charging | Green | Disclose affiliates. Show only verified chargers. | No |
| C4 Upkeep referrals | Green | Disclosure only. | No |
| C5 Movers | Green | Disclosure. Don't suggest curbs are reserved for a truck: NYC permits needed (a "moving" permit, verify). | No |
| C6 Car share | Green | Disclosure. | No |
| D1 Neighbor rewards | Yellow | Paying people for reports can pull us to promos law (NY sweepstakes rules if a prize draw, GBL 369-e, verify) and cause fake reports. Apple 5.3 and 1.2 for UGC. | Light |
| D2 Sponsored pins | Yellow | Label clearly as ads (FTC, Apple 2.3). Never on the green layer. | No |
| E1 Fleets | Yellow | B2B contract, accuracy disclaimers, limited liability. Does not fall under IAP. Commercial rules must be right or marked red. | Yes, contract |
| E2 Data API | Yellow | Check NYC Open Data terms and Mapbox terms permit resale ([NYC Open Data terms](https://www.nyc.gov/html/data/terms.html), verify). Mapbox data typically cannot be resold or cached. Our own community data needs privacy review. | Yes |
| E3 Parking score | Yellow | Defamation or fair-housing-style claims are low risk, but the score must be labeled an estimate. | Light |
| E4 City analytics | Yellow | Aggregation only. Government contracting rules (procurement). | Yes |
| F1 Venue emails | Green | Marketing copy follows product truth. | No |
| F2 Dealer bundle | Green | Pro redemption: use Apple offer codes, not a workaround (3.1.1). | No |
| F3 Merch | Green | Standard. Trademark clearance first. | Trademark search |
| F4 Paid early access | Red | Selling a feature for a place we don't cover, with no promise. Looks like a pre-order or crowdfund and may mislead (FTC Act s.5, Apple 3.1.1, 2.3). | Yes |

## App Store summary
- **Must use IAP:** A1, A3, A4, the Guarantee (as part of Pro), any digital feature unlock ([3.1.1](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase)).
- **Must not use IAP (physical or real-world services):** B1, B2, B3, B6 fees ([3.1.3(e)](https://developer.apple.com/app-store/review/guidelines/#other-purchase-methods)).
- **Free to link out or earn commission:** C-list affiliate offers, as long as you are not selling digital content outside IAP.
- **Likely rejection risks:** tips for spots (legality, 1.1/5.x); paid rewards that look like gambling (5.3); sponsor content mislabeled as parking (2.3); sharing location data (5.1.1, 5.1.2); any "guarantee" claim you can't back up (2.3).
- **UGC (D1, B4, Spot Pass):** needs reporting, blocking and removal (1.2) before more community features go live.

## Bottom line

**Safe to build now:** A1, A3, C1, C3, C4, C6, F1, F2, F3 (with trademark check).
**Needs structure first:** A2 (warranty design), A4, D2, D1, B1 referral-only, B5 as a free "Contest" button, B6 information only.
**Needs a lawyer first:** A2, A5, B1, B3, B5 with fees, C2, D3 wording, E1, E2, E4.
**Avoid for now:** B4 tips, B2 car mover, E5 insurance data, F4 early-access sales.

Company basics still open: a trademark search for "WePark" and a LLC review should come before any money flows. Estimate $500-$2,000 for a first search and clearance.
