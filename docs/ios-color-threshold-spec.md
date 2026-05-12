# iOS Color Threshold — Dual-Persona "Free Comfortably" Spec

**Status:** Draft 2026-05-11. Awaiting Kevin's input on the two open questions at §6 before any code starts.
**Owner:** Tech Lead (spec). `@ios-engineer` implements once approved.
**Supersedes:** Nothing yet. This spec proposes amendments to `docs/design/ios-mvp-palette.md` §2.1–2.2 and `docs/ios-mvp-spec.md` §3.7. Do not delete those sections — this doc is the override record; the palette doc and MVP spec are amended in a follow-up PR once Kevin signs off.
**Does NOT block W4 merge.** See §4.

---

## 0. Open questions for Kevin — read before anything else

These two decisions cannot be made unilaterally. Everything else in this spec flows from them.

**OQ-1: Which user is the default?**
The recommendation in §1 picks the short-stay visitor as the primary persona for the map color layer and sets a 6-hour threshold. That means a resident who parks Monday night and wants to know whether Thursday's ASP is a problem will see green — not orange — until Thursday is within 6 hours. They still get the correct "Free until Thu 9:30am" text label when they tap the block. Is that trade-off acceptable to you, or do you want the overnight resident as primary (24h threshold, with visitors having to read the text)?

**OQ-2: Is Option C (persona toggle) worth the added surface area for v1.0?**
The recommendation says no for v1.0. If you feel strongly that the app should serve both personas with equal fidelity on the map color itself — not just in text — say so here and I'll upgrade the recommendation to Option C and spec the settings toggle. That adds roughly one extra `@ios-engineer` session and a `@designer` pass on the settings UI.

---

## 1. Recommendation: Option A — lower the single threshold from 24h to 6h

**This is binding if Kevin confirms OQ-1 and OQ-2 above.**

Replace `ParkingRulesEngine.nearFutureWindow: TimeInterval = 24 * 3600` with `6 * 3600`. No new enum cases. No new colors. No settings UI. No new screen.

The single constant change produces this updated semantic for `freeButRestrictionSoon` (orange) and `freeComfortably` (green):

| State | Threshold after this change | Previous threshold |
|---|---|---|
| `freeComfortably` (green) | Block is free now and no restriction in the next **6 hours** | >24h away |
| `freeButRestrictionSoon` (orange) | Block is free now but a restriction starts in the next **6 hours** | <24h away |

All other states (`restrictedNow`, `meteredActive`, `unknown`) are unaffected.

---

## 2. Rationale

### The two personas

Kevin surfaced a real product-design tension during W4 verification on 2026-05-11. Both of these users are genuinely in the app:

**Overnight resident** — parks at 11pm, leaves the car for 1–3 days, wants to know if they need to move tomorrow morning. For this persona, a block with ASP at 9:30am the next day is a problem — they care about the 12–20 hour horizon.

**Short-stay visitor** — parks for a 1–3 hour errand (lunch, meeting, appointment). For this persona, a block with ASP at 9:30am tomorrow is irrelevant — they'll be gone by 4pm today. What they care about is the next 2–6 hours.

The current 24h threshold was implicitly designed for the resident. It paints a block orange when cleaning is 20 hours away, which reads as "watch out" for the visitor when the correct reading is "this is a perfect spot for my errand."

### Why the visitor is the right default for the map color layer

The map color is a glance-layer signal. Someone driving slowly on Bowery, scanning the map for somewhere to park for a dentist appointment, needs an instant "go / caution" read. The visitor use case is the highest-frequency, highest-urgency interaction: they need to pull over in the next 60 seconds.

The resident's use case is lower urgency — they park once, then rely on the text label ("Free until Thu 9:30am") and the notification to manage the restriction. The text label is always shown on tap, regardless of what color the polyline is. A resident who parks on a block that turns from green to orange 18 hours later will still get the correct "Free until Thu 9:30am" label in the block detail sheet and will still get the "Move your car" notification before the restriction. The color at parking time is one data point; the label and notification are the safety net.

6 hours is the right threshold for the visitor because it covers the realistic upper bound of a short-stay visit (lunch + errands might be 3 hours; an afternoon appointment might run 2–4 hours). A block that turns orange at the 6-hour mark is genuinely giving the visitor actionable caution: "your errand may run into this." A block that turns orange at 24h is giving the visitor false caution.

### The cost to the overnight resident

A resident parking Monday night on an ASP_TUE_FRI block sees green, not orange. ASP is Tuesday 9:30am — about 14 hours away. With the 24h threshold, they would have seen orange at parking time. With the 6h threshold, the block is green until ~3:30am Tuesday, when they are asleep and will not be watching the map. They still get:

1. The text label ("Free until Tue 9:30am") when they tap the block before parking.
2. The "Move your car" notification at 8:30am Tuesday (W6), which fires 1 hour before the restriction.

The resident does not lose the essential safety net. They lose one visual signal at parking time — the block was orange, now it's green. Given that the primary interface for the resident is the notification (not the map color), this is the right trade-off for MVP.

### Why not Option B (two greens)

Adding a second green case introduces semantic complexity that is not justified for a TestFlight-phase product. Two shades of green are visually subtle and hard to distinguish on a real-world map. The mental model ("green means go, orange means caution") is clean and maps to Apple HIG semantics (green = success, orange = warning). Splitting green into "very green" and "pale green" adds a color that does not have a corresponding Apple system semantic, requires a new `CurrentState` enum case, a new `ParkingColors` constant, a palette doc update, an accessibility label update, and new parity test snapshots — all for a signal that the text label already provides on tap. Post-TestFlight user feedback may reveal this nuance is worth the cost; for MVP it is not.

### Why not Option C (persona toggle)

A settings toggle that changes the threshold is the most product-correct answer but adds scope that is not justified before any real users have been observed. We do not yet know which persona dominates the actual user base. Building a toggle before we have that data is premature product engineering. The PRODUCT.md roadmap lists "Park Until" filter (Tier 2) and route scoring as future investments; those features will give the resident persona a purpose-built tool. The toggle is a good idea for v1.1 once we have TestFlight data showing which persona is under-served.

### Why not Option D (do nothing, ship 24h)

Kevin's instinct that "green should show if it's free for the next 6 hours" is correct. The 24h threshold was a default assumption that was never user-tested. Shipping it as-is would make the map systematically wrong for the higher-frequency use case. The fix is trivial (one constant), low-risk, and does not require a new screen or settings UI. Deferring it means shipping a known product defect.

### PWA precedent

The PWA's `actionableSafetyLabel` at `index.html:5457` does not use a threshold for color at all — the PWA shows block colors by static category, not dynamic state. The 24h threshold is a new construct introduced in W1.5 (iOS palette spec) with no PWA precedent to preserve. The PWA has a "Park Until" mode (`index.html:4220`) that is the closest analog to the short-stay visitor use case — it takes a user-supplied time window and colors blocks green/red based on whether there is a restriction before that time. "Park Until" mode is the explicit per-errand tool. The iOS map color layer is the ambient, always-on read; 6h is the right ambient horizon.

---

## 3. Implementation surface

### What changes

**`ParkingRulesEngine.swift`**

One constant:
```
// Before
static let nearFutureWindow: TimeInterval = 24 * 3600

// After
static let nearFutureWindow: TimeInterval = 6 * 3600
```

That is the only required code change. The engine's `currentState(for:at:)` method already uses this constant; all downstream callers (color mapping, `freeButRestrictionSoon` detection) pick it up automatically.

No new `CurrentState` enum cases. No new `ParkingColors` constants. No new files.

**Parity tests in `WeParkTests/`**

The parity tests include cases with hard-coded hour expectations. Any test that asserts a segment is `freeButRestrictionSoon` or `freeComfortably` based on a time distance in the 6–24h range will need to be updated. Specifically:

- Tests where a restriction is 8–23 hours away: previously `freeButRestrictionSoon`, now `freeComfortably`. Update expected state.
- Tests where a restriction is 1–5 hours away: still `freeButRestrictionSoon`. No change.
- The current W3 suite has 43 tests. The `@ios-engineer` must audit every test that touches `currentState` or `currentStateColor` and update thresholds accordingly. Estimate: 5–10 tests affected. No tests are deleted — they are updated.

The W4 QA report (`docs/qa/w4-pass-1-2026-05-11.md`) AC-W4.4 parity samples include samples 3 and 5 where a restriction is 16–22 hours away and the expected state is `freeButRestrictionSoon` (orange). After this change, both would be `freeComfortably` (green). The parity test for those samples should be updated before this threshold change lands.

**`docs/design/ios-mvp-palette.md`**

Section 2.1 (the table and example) must be updated. The replacement text for the orange row is:

> **Free now, restriction coming soon** — ASP block whose next active window starts within ~6 hours. Warning state. Fine if you're staying less than 6 hours; set a timer if you are. Orange.

The "Same block, different color through the week" example must be recalculated:

| Wall-clock time (ET), ASP_MON_THU (Mon + Thu 7–9:30am) | Current state | Color |
|---|---|---|
| Mon 7:00–9:30am | ASP active | Red |
| Mon 9:30am – Thu 1:00am (next ASP > 6h away) | Free now, far from next | Green |
| Thu 1:00am – Thu 6:59am (within 6h of next ASP) | Free now, restriction coming | Orange |
| Thu 7:00–9:30am | ASP active | Red |
| Thu 9:30am – Mon 1:00am (next ASP > 6h away) | Free now, far from next | Green |

The exact threshold note ("24h" appears twice in §2.1) updates to "6h" in both places.

Section 2.2 (the `nearFutureWindow` comment in the pseudocode block) updates to `6 * 3600`.

**`docs/ios-mvp-spec.md`**

Section 3.7 orange row description updates from "≤24h" to "≤6h." The palette doc is the primary spec; §3.7 is a summary reference.

### What does NOT change

- The `CurrentState` enum (5 cases, same as today)
- The `ParkingColors` enum (5 constants, same as today)
- The `actionableSafetyLabel` / `safetyLabel` text output — "Free until Thu 9:30am" is still correct for both personas; only the color encoding changes
- The 14-day walker logic in `computeNextRestrictionHours`
- The suspension skip logic
- The metered threshold (metered billing is hour-by-hour, already handled separately via `meteredActive` detection, not `nearFutureWindow`)
- The notification lead time (still 1 hour before the restriction — W6 spec unchanged)
- The block detail sheet text — "Free until Thu 9:30am" is always shown correctly regardless of threshold

### Effort estimate

`@ios-engineer`: 1 session.
- Update the `nearFutureWindow` constant (5 minutes).
- Audit and update parity tests in `WeParkTests/` (30–45 minutes — need to check each `currentState` test case against the new 6h boundary).
- Run the full test suite to confirm pass.
- Update the palette doc and MVP spec textual references (15 minutes — prose only, no code).

`@qa-verifier`: one targeted pass covering:
- Confirm the constant changed
- Confirm test suite still passes (new threshold, updated expectations)
- Spot-check 3 of the updated test cases against the expected new state
- Confirm palette doc example is recalculated correctly

Total: less than one day of calendar time.

---

## 4. W4 scope — this spec does NOT block W4 merge

The W4 PR (`ios/w4-block-detail`, at commit `254ef36` per the QA report) is in fix-pass as of 2026-05-11. The two blocking findings (VoiceOver order, ✕ dismiss animation blank) are in `ParkingRulesEngine` and `ContentView` / `BlockDetailView` — they are correctness fixes independent of the threshold constant.

The threshold change proposed here touches `nearFutureWindow` in `ParkingRulesEngine.swift` and the parity tests in `WeParkTests/`. The W4 fix-pass does not touch either of those. There is no merge conflict.

**Ship W4 first.** The threshold change lands as a separate PR after W4 is merged to main. Suggested branch name: `ios/color-threshold-6h`. Suggested stream designation: **W4.5** (a cleanup/tune stream between W4 and W5, lightweight enough to not warrant its own work-stream number in the MVP spec).

The W4 fix-pass must address the two QA blocking findings (#1 VoiceOver order, #2 ✕ dismiss blank) and get the full test suite to confirm 43/0 on a low-memory machine before squash merge. The threshold change is a follow-on PR, not a prerequisite to W4 merge.

---

## 5. A/B testability — staged rollout path

For v1.0 TestFlight (the current build), the recommendation is Option A (6h, single threshold). No feature flag needed because TestFlight is internal-only; Kevin is the first tester.

If Kevin wants to compare 24h vs. 6h with real users post-public launch, the following staged path is available:

**v1.0 (TestFlight):** Ship with 6h threshold. Observe whether Kevin himself or any beta testers call out "the map showed green but I should have known to move for ASP." If no one complains about green-when-orange-would-help, the 6h threshold is validated.

**v1.1 option — Option C toggle (if OQ-2 answer changes):** Add a settings toggle "Parking duration: Quick stop / Overnight" that maps to a `userPreferredWindow` of 6h or 24h respectively. This toggle can be introduced without a new map screen or onboarding flow — one `UserDefaults`-backed Bool in `SettingsSheet`, read by `ParkingRulesEngine.nearFutureWindow` as a computed property instead of a constant. The `ParkingRulesEngine` would need to take the window as a parameter (or read from a shared settings service); the `CurrentState` enum would still have the same 5 cases. Estimate: 1 extra `@ios-engineer` session + `@designer` review of the Settings UI.

**v1.1 option — "Park Until" mode (PRODUCT.md Tier 2):** The PWA's "Park Until" feature (`index.html:4220`) is a more powerful solution for the short-stay visitor than a threshold toggle — it lets the user specify exactly when they're leaving and colors blocks accordingly. If v1.0 reveals that visitors need even more precision than 6h provides, "Park Until" mode is the right next investment. It does not require any change to the threshold; it's a new map mode layered on top of the existing engine.

---

## 6. Open questions for Kevin

Listed again in decision-ready form. Both are blocking for the `@ios-engineer` to start this work.

**OQ-1:** Is 6h the right threshold, or do you want a different number?
- 6h is the spec's recommendation based on "the next 1–6 hours" in your original message and the logic above.
- If you want a more conservative visitor default (e.g., 4h), that is a single-number change in this same spec before dispatch.
- If you want 12h (catches overnight parking in a way 6h doesn't but is still visitor-friendlier than 24h), that is also viable. 12h is a natural "overnight" horizon; an ASP at 9am 11 hours from now would read orange, which is relevant even for a visitor staying late.

**OQ-2:** Is Option C (the persona toggle) worth the extra scope for v1.0 TestFlight?
- Recommendation: no. Ship Option A (6h) for v1.0. Add the toggle in v1.1 if TestFlight reveals the overnight-resident population is meaningfully under-served by a 6h threshold.
- If your answer is yes, say so and I will spec the toggle in a follow-on doc before `@ios-engineer` starts.

---

## 7. Sections of existing docs to rewrite once OQ-1 and OQ-2 are confirmed

These rewrites happen in the same PR as the constant change. The `@ios-engineer` owns both.

| Doc | Section | Change |
|---|---|---|
| `docs/design/ios-mvp-palette.md` | §2.1 table, orange row | Update threshold number and description |
| `docs/design/ios-mvp-palette.md` | §2.1 "Same block, different color" example | Recalculate transition times using 6h |
| `docs/design/ios-mvp-palette.md` | §2.2 pseudocode comment | Update `nearFutureWindow` comment |
| `docs/ios-mvp-spec.md` | §3.7 color-to-state table, orange row | Update ≤24h → ≤6h |

The decision log entry in `docs/design/ios-mvp-palette.md` §7 should get a new row:

> 2026-05-11 — `nearFutureWindow` lowered from 24h to 6h. Dual-persona analysis surfaced during W4 verification; 6h chosen to serve the short-stay visitor as the primary map-color persona. Overnight resident served by text label + W6 notification. See `docs/ios-color-threshold-spec.md`.

---

## 8. Out-of-scope follow-ups (punted with rationale)

**"Park Until" mode for iOS.** The PWA's `renderParkUntilMode` at `index.html:4220` lets visitors specify their exact departure time and see only blocks safe for that window. This is the most precise solution for the short-stay visitor and is listed in PRODUCT.md Tier 2. It is out of scope for this spec because it requires a new map mode, new UI controls, and a new engine function. Post-TestFlight, after the resident vs. visitor ratio in the user base is known, this is the right next investment.

**Drive Mode threshold.** Drive Mode (deferred per `docs/ios-mvp-spec.md` §2.2) will need its own color-threshold decision when it ports. A driver scanning blocks while moving has an even shorter time horizon than a visitor on foot. That spec will reference this one.

**12h as an intermediate option.** A 12h threshold would cover both the visitor (anything within their errand is fine) and the early-morning resident (ASP at 9am is 8h away — orange by midnight, giving them a visual warning before bed). If Kevin's answer to OQ-1 moves toward the resident persona, 12h is a strong compromise worth reconsidering before code starts.
