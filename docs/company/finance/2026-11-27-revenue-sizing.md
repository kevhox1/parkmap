# Revenue sizing: back-of-envelope (2026-11-27)

Draft for Kevin. Rough math, not a forecast. Not investment, tax or accounting advice. Almost every input is an **estimate** because we have no usage analytics yet. All figures are **per year, gross unless stated**.

## Shared assumptions

| Input | Value | Status |
|---|---|---|
| Pro price | $4.99/mo, $29.99/yr | Known (business-model.md) |
| Payer mix | 70% annual, 30% monthly. Monthly payers stay ~4 months | Estimate |
| Revenue per Pro payer per year | ~$27 gross, ~$23 net of Apple 15% | Estimate |
| Apple cut | 15% (Small Business Program, under $1M/yr; needs enrollment). 30% above that | Known, Apple policy |
| Apple cut on physical services, garages, B2B | 0% (Guideline 3.1.3(e); off-app sales) | Per Kevin's note |
| Stripe / Apple Pay card fee | 2.9% + $0.30 per charge | Public pricing, verify |
| Manhattan street-cleaning (ASP) ticket | $65 | Sourced: [ABC7](https://abc7ny.com/post/alternate-side-parking-fines-going-up-in-nyc-dsny-says/5948335/), [nyc.gov/asp](https://www.nyc.gov/asp). One older city PDF shows $50, so confirm on the [DOF violation page](https://www.nyc.gov/site/finance/vehicles/services-violation-codes.page). A repeat-offense bill ($100) was proposed; I found no proof it passed |
| Scale | 1k / 10k / 100k monthly active drivers (MAD) | Kevin's brief. 100k is a big share of Manhattan, so treat as a stretch |

---

## A1. WePark Pro

| Assumption | Value |
|---|---|
| Free-to-paid | 3% of MAD (range 2-5%) estimate |
| Support | ~$0.50 per payer per year (Apple handles refunds) estimate |

| MAD | Payers | Gross | Net of Apple 15% |
|---|---|---|---|
| 1k | 30 | $810 | ~$690 |
| 10k | 300 | $8.1k | ~$6.9k |
| 100k | 3,000 | $81k | ~$69k |

Running cost: Apple cut, small support. Cloud and map costs are in `costs.md`. Effort: **M** (StoreKit 2 paywall, already specced). Verdict: the baseline. It pays for hosting, not salaries, until well past 10k drivers.

## A2. Ticket Guarantee (upgrade tier, about $7.99/mo)

| Assumption | Value |
|---|---|
| Incremental price | +$3/mo = ~$36/yr gross, ~$30.50 after Apple |
| Share of Pro payers who upgrade | 30% estimate |
| Parks per year that rely on a green signal | 150 (about 3 a week) estimate |
| Share of wrong greens that get ticketed | 30% estimate |
| Share of tickets actually claimed | 70% estimate |
| Payout per claim | $65 |

**Payout cost per subscriber per year** = 150 x error rate x 0.3 x 0.7 x $65:

| Green accuracy | Payout per subscriber per year |
|---|---|
| 99.5% | ~$10 |
| 98% | ~$41 |

Break-even accuracy is about 98.5%. Below that, each subscriber costs more than the upgrade brings in.

| MAD | Upgraders | Incremental net, 99.5% | Incremental net, 98% |
|---|---|---|---|
| 1k | 9 | ~+$180 | ~-$90 |
| 10k | 90 | ~+$1.8k | ~-$940 |
| 100k | 900 | ~+$18k | ~-$9.4k |

Not counted: fraud and bad-faith claims (cap claims, require proof the pin was on green), staff time per claim, and any lift in Pro conversion from the marketing hook. A capped guarantee could be worth more as a brand story than as a profit line. Effort: **M** (claims flow, proof logging). **Needs a lawyer first (could be treated as insurance under NY law).** Verdict: pilot only after we measure real green accuracy.

## A3. Visitor Day Pass

| Assumption | Value |
|---|---|
| Price | $2.99 one-time; Apple 15% leaves ~$2.54 |
| Visitors in MAD | 20% (they churn monthly, so new ones must be found each month) |
| Visitors who buy a pass | 5% a month |

| MAD | Passes/yr | Gross | Net |
|---|---|---|---|
| 1k | 120 | $359 | ~$305 |
| 10k | 1,200 | $3.6k | ~$3.0k |
| 100k | 12,000 | $35.9k | ~$30.5k |

Effort: **M** (consumable IAP, time-limited entitlement). Verdict: small money, and visitors are hard to reach. Revisit with Plan a Trip.

## C1. Garage fallback affiliate

| Assumption | Value |
|---|---|
| "No green nearby" garage cards shown | 2 per MAD per month |
| Tap rate | 5% |
| Tap to booking | 20% |
| Average booking / commission | $30 / 10% = $3 (**unverified**). **Correction (orchestrator, same day):** `@partnerships` found SpotHero listed at ~2.4% via FlexOffers (~$0.72/booking), so scale every C1 figure by ~0.24. At 10k MAD that is ~$1.7k/yr, not ~$7.2k. |

That is ~$0.06 per MAD per month, ~$0.72 per year.

| MAD | Gross/yr |
|---|---|
| 1k | ~$720 |
| 10k | ~$7.2k |
| 100k | ~$72k |

Running cost: near zero (no Apple cut; the sale is off-app). Effort: **S**. Verdict: cheapest idea and it fixes the "no green" dead end. Scales with all drivers, free ones too.

## B1. Car services (snow dig-out first)

| Assumption | Value |
|---|---|
| Orders | 2% of MAD per year (snow), estimate; NYC has only a few big storms a year |
| Average job | $80 estimate |
| WePark take | 20% = $16 |
| Card fee (2.9% + $0.30 on $80) | ~$2.60 |
| Support, no-shows, refund reserve | ~$3.50 per order estimate |
| Net per order | ~$10 |

| MAD | Orders/yr | Gross take | Net |
|---|---|---|---|
| 1k | 20 | $320 | ~$200 |
| 10k | 200 | $3.2k | ~$2.0k |
| 100k | 2,000 | $32k | ~$20k |

Adding washes and jump starts might double or triple this. Effort: **L** (recruit and vet providers, dispatch, payouts, disputes). Flag for an accountant: sales tax on services, contractor payments and 1099s, and liability. Verdict: seasonal and operationally heavy for small money. Test with a referral link, not a marketplace.

## E1. WePark for Fleets (customer counts)

| Assumption | Value |
|---|---|
| Vehicles per customer | 6 estimate |
| Price | $15 per vehicle per month = $1,080/yr per customer estimate |
| Fees | Invoice or ACH (~0.8%, capped) or card 2.9%; no Apple cut |
| Support/onboarding | ~15% of revenue estimate |

| Customers | Gross/yr |
|---|---|
| 10 | ~$10.8k |
| 100 | ~$108k |
| 1,000 | ~$1.08M |

Effort: **L** (commercial rules, multi-vehicle accounts, admin view, sales). Needs real interviews to confirm that willingness to pay exists. Verdict: biggest revenue per customer; validate with 5-10 fleet owner conversations before building anything.

## E2. Curb data API (customer counts)

| Assumption | Value |
|---|---|
| Average contract | $20k/yr (small apps ~$12k, large buyers ~$60k) estimate |
| Sales cycle | 6-12 months estimate |

| Customers | Gross/yr |
|---|---|
| 2 | ~$40k |
| 10 | ~$200k |
| 50 | ~$1M |

Running cost: data freshness, uptime promises, legal check on NYC open-data terms. Effort: **L**. Verdict: lumpy and slow. The data must be proven first; 1-2 customers in a year is the realistic bar.

---

## Summary

| Idea | Revenue at 10k drivers (gross/yr) | Effort | Risk |
|---|---|---|---|
| A1 Pro | ~$8.1k | M | Low. Conversion unknown |
| A2 Guarantee | ~+$1.8k at 99.5%, loss at 98% | M | High (legal, data accuracy) |
| A3 Day Pass | ~$3.6k | M | Medium (hard to reach visitors) |
| C1 Garage affiliate | ~$1.7k at the ~2.4% rate found (~$7.2k only if 10%) | S | Low |
| B1 Snow dig-out | ~$3.2k | L | High (operations, liability) |
| E1 Fleets* | ~$10.8k at 10 customers | L | Medium (demand unproven) |
| E2 Curb API* | ~$40k-$200k at 2-10 customers | L | High (slow sales, data trust) |

*Counted by customers, not drivers. 10 customers shown for E1; E2 shows 2 to 10.

Takeaway: at 10k drivers no consumer idea clears ~$10k a year. Consumer money only gets meaningful near 100k drivers. B2B is where dollars per customer are high.

## Top 3 for the next 12 months

1. **A1 Pro.** Already planned, and it is the base for everything else. Enroll in Apple's Small Business Program before launch.
2. **C1 Garage fallback.** Small build, earns on free users, and makes "no green" useful. Confirm real commission terms first.
3. **E1 Fleets, as a research project.** Do interviews now, with no build. If 3 or more owners say they would pay, it can beat all consumer lines combined.

Hold A2 until we measure green accuracy and a lawyer has weighed in. It is a brand play, not a profit line.

## Needs a professional

- Lawyer: Ticket Guarantee (insurance rules), service-provider liability.
- Accountant: sales tax on services, contractor payments, entity setup before real revenue.
- All sizing inputs above should be replaced with real data once TestFlight analytics exist (`@data-analyst`).
