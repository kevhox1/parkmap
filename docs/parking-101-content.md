# Parking 101 content — for `ParkingGuideView`

Source of truth for the in-app "Parking 101" beginner's guide (`FT-12`,
`docs/ft12-beginners-manual-spec.md`). `@ios-engineer` renders this as a scrollable,
sectioned view with a quick-jump chip row, reached from a "Parking 101" row in
`SettingsView` (above "Help & FAQ") and from a one-shot first-launch banner. Keep copy
plain, calm, beginner-first — same voice as `docs/in-app-faq-content.md` — except the
Pitch section, which is allowed to be warmer/more encouraging (OQ-5).

Every dollar figure below is backed by a named constant in
`ios/WePark/WePark/Services/Constants.swift` (`MoneyMathConstants`) — this doc must not
drift from those constants. If a figure changes, update both.

---

## Screen title: **Parking 101**
Subtitle: *Free parking in NYC is doable. Here's how.*

Quick-jump chips: **The Pitch** · **Sign School** · **Map Colors** · **Rookie Mistakes**

---

## Section (a) — The Pitch

**Free parking in NYC is a routine, not a gamble.**
Alternate-side parking (ASP) means moving your car off one side of the street about
twice a week, around a posted window — and it's suspended roughly 40 days a year on
holidays and emergencies. That's the whole trick. WePark's color-coded map and
reminders do the remembering for you, so you just need to learn the rhythm once.

**The money math.**
Manhattan garages commonly run **$500–$1,000+/month**; citywide the average is closer
to **$400–$600/month**, depending on the neighborhood (market rates vary — see the
source note below). Free street parking costs **$0**, but it takes the habit of moving
your car on schedule, and if you miss a window you risk a street-cleaning ticket around
**$65** — the same figure WePark's Help & FAQ uses. WePark's reminders exist specifically
to keep that from happening.

Put together: that's roughly **$4,800–$12,000 a year** back in your pocket if you're
willing to learn the rhythm — a straight 12-month multiple of the monthly range above,
nothing invented.

*Figures vary by neighborhood, season, and provider — these are market-data estimates,
not official city pricing. Source: SpotAngels and SpotHero NYC monthly-parking listings,
pulled 2026-07-09.*

---

## Section (b) — Sign-Reading School

**ASP / Street cleaning signs.**
A real plate reads something like **"NO PARKING 8-9:30AM TUES FRI STREET CLEANING."**
There's no broom icon on the actual sign — just the restriction, the days, and the
window. Outside that window, or on a suspended day, you're free to park there.

**The 3-tier restriction ladder.** The single most-misunderstood distinction for new
drivers — and the actual legal test between the first two tiers is *what* you're
allowed to load: No Parking permits passengers **or merchandise**; No Standing
permits passengers **only**, never cargo. That's the real difference, not whether the
driver stays in the car:

| Sign says | You may... | You may NOT... |
|---|---|---|
| **NO PARKING** | Stop to actively load or unload passengers **or merchandise** | Leave the car parked, or idle with no active loading/unloading happening |
| **NO STANDING** | Stop to actively pick up or drop off **passengers only** — no merchandise | Load or unload cargo, or remain in the car for any other reason |
| **NO STOPPING** | Nothing, except to obey a traffic signal, sign, or a police officer | Stop for any other reason, not even to drop someone off |

**Metered / Muni-Meter signs.**
A plate reading **"PAY TO PARK 8AM-7PM"** (or similar) means: pay during those posted
hours. Outside them, and on major legal holidays, parking there is free.

**Hydrant 15-foot rule.**
No sign is posted for this one — it's a universal NYC rule. Stay at least 15 feet from
a hydrant on either side, roughly a car length. Standing there "just for a second" still
counts as a violation.

**Arrows and side-of-street semantics.**
A sign with an arrow applies in the direction the arrow points, up to the next sign or
the corner — not the whole block, and only on that side of the street.

**Combined sign stacks.**
Multiple plates on one pole means all of the rules apply at the same time. Read top to
bottom, and the most restrictive rule in effect at a given moment wins. This is the same
"reading the signs" rule from Help & FAQ — Sign School just adds the visuals.

---

## Section (c) — How WePark's Colors Map to Signs

- 🔴 **Red** — a restriction (No Parking / No Standing / No Stopping window, or an ASP
  window) is active right now.
- 🟠 **Orange** — free right now, but the posted restriction starts within 6 hours.
  Fine for a quick errand; set a reminder for anything longer.
- 🟡 **Amber-yellow** — a metered sign, and the meter is currently active. Pay or move.
- 🟢 **Green** — free right now, with nothing posted in the near term.
- ⚪️ **Gray** — WePark has no data for this block. The sign on the pole is the only
  truth here.

---

## Section (d) — Rookie Mistakes / Gotchas

- ASP resumes the very next day after a suspension — don't assume a holiday break rolls
  over.
- Check **both** the day letters and the time window on a sign, not just one.
- A lower second plate on the same pole can change everything the top plate says — read
  the whole stack.
- Some meters run different hours than you'd assume. Always check the plate; don't
  guess from a nearby block.
- Standing "just for a second" near a hydrant is still a violation.
- A green WePark block is a snapshot of right now — recheck if you're staying past the
  horizon shown.
- "No Parking" still allows a quick stop to load or unload. It's not a full ban — see
  the 3-tier ladder above.

---

## Sourcing note (money math, §a)

- SpotAngels, "The 2026 Ultimate Guide to Cheap Monthly Parking in NYC" —
  https://www.spotangels.com/blog/the-ultimate-nyc-monthly-parking-guide/
- SpotAngels, "Manhattan Monthly Parking — Best Rates & Deals" —
  https://www.spotangels.com/nyc/manhattan-monthly-parking
- SpotHero, "New York, NY Monthly Parking" — https://spothero.com/city/monthly/nyc-parking
- Street-cleaning ticket figure ($65) — reused verbatim from `docs/in-app-faq-content.md`
  (line 18) / `FAQHelpView.swift`. Do not introduce a second figure for the same thing.

Pulled 2026-07-09. These are private-market aggregator figures, not an official DOT
price list — a future refresh only needs to touch `MoneyMathConstants` in
`Constants.swift`; this doc should be updated in the same change.
