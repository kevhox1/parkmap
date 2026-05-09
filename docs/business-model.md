# WePark — Business Model

**Status:** Directional, locked 2026-05-08. Revisit after MVP TestFlight ships and we have ~10–100 real-user sessions of feedback.

This doc captures the planned monetization shape for WePark. It is **not yet implemented** — MVP ships free for everyone in TestFlight and adds the paywall in v1.1 once the product is validated.

---

## 1. Strategy at a glance

**Free + WePark Pro (single tier).** Subscription with a 7-day free trial, gated on the highest-value feature: notifications.

The unique selling argument is concrete: **one avoided ASP ticket in NYC ($65–115) pays for ~13 months of monthly subscription.** Few subscription apps have ROI math this clean.

---

## 2. Free vs Pro feature split

### Free tier (always available, App Store install)

- Map of Manhattan with parking regulations color-coded
- ASP suspension banner for today/tomorrow
- Tap-a-block to see "Free until Thu 9:30am" / "No parking" / etc.
- "Park here" pin (drops, persists across launches)
- Mute toggle (cosmetic — no notifications to mute on Free anyway)

### WePark Pro (paid)

- ✅ **"Move your car" local notifications** — the MVP killer feature; the reason to install over the PWA
- ✅ **Drive Mode** — when ported from PWA. Currently the strategic moat per [HANDOFF.md:18](HANDOFF.md).
- ✅ **Threat Tracker** — sweeper / ticket-agent / tow alerts when ported
- ✅ **Zone chat** — pseudonymous neighborhood chat per zone, when ported
- ✅ **Future:** Smart Move recommendations, Find Parking Near Me, address search, snow emergency overlays

**Design principle.** Don't put core "look at the map and learn the rules" functionality behind the paywall. That's the demo. The paywall gates the *automation* — being told what to do, when, and where. That's what justifies a recurring fee.

---

## 3. Pricing

| Plan | Price | Effective monthly |
|---|---|---|
| Monthly | **$4.99/mo** | $4.99 |
| Annual | **$29.99/yr** | $2.50 (40% discount) |
| Free trial | **7 days** | $0 |

Why these numbers:

- **$4.99 monthly.** Industry standard for utility-app subscription pricing on iOS (SpotAngels, ParkWhiz Pro, similar utilities are in the $3.99–$6.99 range). Below the psychological "is it worth a Netflix sub?" threshold.
- **$29.99 annual.** 40% discount drives commitment, smooths cash flow, and reduces per-user churn-calculation noise. Standard ratio.
- **7-day trial.** Long enough to experience at least one ASP cycle (Mon+Thu street cleaning is twice a week in most NYC zones). User *experiences* the notification value, not just hears it pitched.

**Pricing is not locked forever.** Re-evaluate after first 100 paying users. If conversion is high, can experiment with $5.99 or $6.99 monthly. If trial-to-paid conversion is low, the issue is product, not price.

---

## 4. Trial & paywall mechanism

- **StoreKit 2** for billing (Apple's modern API; well-documented).
- **Apple Auto-Renewable Subscription** product type. Apple handles trial enrollment, billing, refunds, restoration, expiration, and grace-period logic natively.
- **Single subscription product** in App Store Connect (with monthly + annual options inside it). Don't create separate products for monthly vs annual — they live as variants of one subscription.
- **Paywall UX appears** at:
  1. First pin drop after Day 1 (gives free users one taste of the pin flow before asking).
  2. Settings → "Upgrade" entry point (always available).
  3. Edge of any future-Pro feature (Drive Mode, Tracker) when first opened.
- **Restore purchases** button mandatory (App Store review will reject without it).

---

## 5. MVP-launch posture (the actual decision for now)

**Ship MVP completely free. No paywall. No StoreKit integration in v1.0.**

Reasons:

1. **No real users yet to validate willingness-to-pay.** Building paywall machinery before product-market fit is wasted work.
2. **TestFlight users are friends/early-adopters.** Charging them is bad form and tilts feedback (people who paid feel obligated to be polite).
3. **App Store review for IAP is fussier.** First app submission is easier without it; add IAP in v1.1 once the app's first review is green.
4. **Cleaner dev path.** `@ios-engineer` ships W1–W8 without monetization complexity. Saves ~5–7 days of dev work that's better spent on the product.

**v1.1 paywall work** is its own future spec: `docs/ios-paywall-v1.1-spec.md`. Triggered when:
- MVP is on TestFlight with at least 10 active testers
- Notification feature is verified working in real-world ASP cycles
- Kevin has decided the model still feels right after seeing real usage

---

## 6. Customer support plan

Pragmatic, scaled by user count:

| Stage | User count | CS approach |
|---|---|---|
| **TestFlight** | 1–100 | Kevin handles directly via email. ~5 min/day. No infrastructure. |
| **Early launch** | 100–500 | Kevin still primary, with FAQ doc to copy-paste from for common issues. Set up a generic `support@wepark.app` email. |
| **Paying-user scale** | 500+ | `@customer-support` agent pre-drafts replies in inbox. Kevin reviews + approves. Categorizes & files bug reports as GitHub issues automatically. |

**What agents handle well:**
- L1 triage ("notifications aren't working" → walk through Settings)
- FAQ matching against an inbound email
- Bug-report intake → file as GitHub issue
- Sentiment classification (escalate angry users to Kevin's direct attention)

**What agents do NOT handle:**
- Refunds — Apple handles directly; users go through App Store, not us
- Account/payment disputes — App Store
- Empathy — escalate to Kevin

**Don't build this until needed.** TestFlight CS volume is low; over-engineering is waste. Set up `@customer-support` agent at the 500-user mark, not before.

---

## 7. Revisit triggers

Conditions that should prompt a fresh business-model conversation:

1. **MVP ships and Kevin doesn't love the proposed paywall placement.** Conversion data lives downstream; product instinct should override paper plans.
2. **TestFlight feedback shows Pro features aren't differentiated enough to justify $4.99/mo.** May need to pull more from the roadmap into Pro (e.g., Smart Move, address search) or rethink pricing.
3. **A clear "$X to pay annually for the whole year, no monthly option" signal from real users.** Some utility-app audiences strongly prefer one-and-done.
4. **A trademark or domain dispute on `wepark.app` / `wepark.com`.** Could shift bundle ID and seller name, which affects paywall messaging.
5. **An acquisition or licensing offer.** WePark's data layer (the merged ASP + main NYC sign dataset) could itself be valuable to city planners or delivery cos per [PRODUCT.md:93](PRODUCT.md). Different exit strategy = different model.
6. **Kevin's financial goalpost shifts.** He's currently on goal "B/C" (real income / fundable). If that becomes "A" (cover Apple Dev fee + see what happens), the model simplifies dramatically.

---

## 8. What this doc is NOT

- **Not a forecast.** No projected ARPU, MAU, conversion rate, or LTV/CAC numbers. Those are speculative until v1.1 ships and we have data.
- **Not a marketing plan.** How to *acquire* the users who pay is a separate conversation. The QR-code-on-windshield idea from [HANDOFF.md:46](HANDOFF.md) is one input there.
- **Not a corporate structure plan.** WePark is currently under Kevin Hoxha's individual Apple Developer account. If/when scale or tax/liability concerns warrant an LLC for WePark specifically, that's a separate conversation, addressed in [HANDOFF.md project memory](.claude/agents/) or a future `docs/legal-structure.md`.

---

## Decision log

| Date | Decision | Notes |
|---|---|---|
| 2026-05-08 | Adopted Free + Pro single-tier model directionally | Discussed in chat; locked as starting point |
| 2026-05-08 | $4.99/mo, $29.99/yr, 7-day trial | Pending real-user validation |
| 2026-05-08 | MVP ships free; paywall lands in v1.1 | Don't waste MVP-week dev on monetization |
| 2026-05-08 | Customer support is Kevin direct → FAQ-assisted → agent-assisted scaling | Build `@customer-support` agent at ~500-user mark |
