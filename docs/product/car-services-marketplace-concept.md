# Car services marketplace (concept, back burner)

**Status:** Idea captured 2026-11-27. Not scheduled. Nothing gets built until Stoop ships and Phase 7 community is live.
**Origin:** Kevin: connect drivers to handymen / TaskRabbit-style workers for car cleaning or snow removal, earning a 20–25% markup or referral fee.
**Owners when picked up:** `@partnerships` (providers, deal terms), `@product-manager` (scope, pricing test), `@legal-compliance` (liability, App Store rules), `@tech-lead` (spec).

## Why it fits WePark

WePark already knows three things no generic task app knows:
1. **Where the car is**, down to the curb (parked-car pin, address-anchored parking).
2. **When the car has a problem coming**: street cleaning, snow emergency, the meter running out, a long stay.
3. **That the owner is often not near it**, since the reminders fire while they're at work or away.

So the offer can show up at the moment of need, already filled in: "Snow emergency tonight. Your car is on W 82nd. Get it dug out by 7 AM for $45?"

## Candidate services (rough order of fit)

| Service | Trigger WePark already has | Notes |
|---|---|---|
| **Snow dig-out / brush-off** | Snow emergency, forecast | Strongest seasonal fit. Highest willingness to pay. Spiky supply. |
| **Alternate-side car moving** ("car sitter") | Street-cleaning reminder | Already an informal NYC market. Needs the keys handed off and a licensed driver, so the liability is the biggest of any service here. |
| **Exterior wash / interior detail at the curb** | Car parked more than N days | Waterless wash fits street parking. Low urgency, good for repeat business. |
| **Jump start / tire air** | User reports "car won't start" | Overlaps with roadside services the user may already have through their insurance. |

## Business models to compare

| Model | How we earn | What we take on |
|---|---|---|
| **Referral / affiliate** | A fee per booking from the platform (TaskRabbit, Angi/Handy, or local operators) | Little: they handle payment, vetting and insurance. Fee likely well under 20–25%. **Verify current partner programs and rates before planning around them.** |
| **Markup (we are the merchant)** | Charge the user and pay the worker, keeping 20–25% | Payments (Stripe or Apple Pay, not in-app purchase, because the service happens off the app), refunds, disputes, vetting, insurance, support. |
| **Lead fee to local operators** | Flat fee per qualified lead | Selling only to a handful of vetted NYC operators. Good for testing demand. |

**Recommended path:** start as **referral/lead-gen** with one or two NYC operators for snow dig-out, to prove demand. Move to the markup model only once volume justifies the payments, support and insurance overhead.

## Things to check before building

- **App Store:** physical services consumed outside the app must not use in-app purchase (guideline 3.1.3(e)/3.1.5). Use Apple Pay or Stripe.
- **Liability:** damage to the car, a worker hurt on the street, a car moved into a ticket or a tow. Who carries the insurance?
- **NYC rules:** shoveling snow into the street, washing cars on the street (water runoff), and whether moving cars for pay needs a license.
- **Privacy:** sending the car's location to a third party needs explicit consent for each booking, and the privacy policy must be updated.
- **Trust:** worker vetting, reviews, and photo proof that the job was done.

## Smallest test (when picked up)

A "Need it dug out?" card on the snow emergency banner that links to one partner's booking page with a referral code. No payments in the app. Measure how many people tap it and how many book. That's a week of work and tells us whether the demand is real.
