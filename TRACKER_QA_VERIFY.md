# Tracker QA Verification

Reviewed branch/state: `tracker-impl-v2` content at commit `a7c13e1`, verified from branch `tracker-qa-verify`
Baseline review: `TRACKER_QA_REVIEW.md` from branch `tracker-qa-review`
Reviewer role: verification only, no implementation changes
Date: 2026-04-07

## Verdict
The priority issues called out in `TRACKER_QA_REVIEW.md` are **not actually fixed** in the current implementation.

What *did* change in this branch is mostly tracker-provider plumbing:
- configurable tracker runtime via `tracker-config.js`
- Supabase provider wiring
- improved tracker auth-gate rendering and retry behavior
- service worker bypass for live Supabase traffic
- tile load retry bookkeeping cleanup

Those are useful infra changes, but they do **not** resolve the previously flagged product/UX risks in Park My Car, Smart Move, Smart Score, or narrow-phone bottom-sheet behavior.

## Re-check of prior findings

### 1. Park My Car CTA mismatch
**Status:** NOT FIXED

The button is still labeled `Park My Car Here` but still calls `openParkModal()` instead of `parkCarHere()`.

**Evidence**
- `index.html:840` uses `onclick="openParkModal()"`
- `index.html:3901` still contains a dedicated `parkCarHere()` helper that is not wired to the CTA

**QA read:** still the same mismatch. The one-tap pin flow is not the primary action.

---

### 2. Pin mode still snaps by nearest vertex, not nearest line geometry
**Status:** NOT FIXED

`findClosestSegment()` still loops raw polyline vertices and picks the segment with the smallest point-to-vertex distance.

**Evidence**
- `index.html:3913` `findClosestSegment(lat, lng)` iterates `for (const pt of latlngs)` and compares squared distance to each vertex only

**QA read:** the wrong-block-face risk remains for long blocks and intersection-adjacent pins.

---

### 3. Future ASP suspensions are still ignored by Smart Score / Smart Move timing
**Status:** NOT FIXED

The logic still only asks `isASPSuspended(dateStr)` for the current date and does not propagate suspension checks into future ASP occurrences.

**Evidence**
- `index.html:2827` `computeBlockScore(...)` still accepts only `aspSuspendedToday`
- `index.html:2890` `computeHoursUntilASP(...)` still walks future scheduled days without checking suspension dates for those future days
- `index.html:2934` `computeNextRestrictionHours(...)` still computes `const suspended = isASPSuspended(dateStr)` for *today* only
- `index.html:2678` Smart Score render path still seeds scoring from today's suspension flag only

**QA read:** holiday / suspended-day mis-scoring remains.

---

### 4. Smart Move still has two recommendation engines that can disagree
**Status:** NOT FIXED

The always-visible panel still uses `computeSmartMove()` while the blue CTA still uses `generateSmartMoveRecommendation()`, which ranks by Smart Score with proximity weighting instead of the Smart Move panel's time-gained-vs-distance logic.

**Evidence**
- `index.html:4113+` `computeSmartMove()` uses its own candidate filters and scoring
- `index.html:4794` `generateSmartMoveRecommendation()` still recomputes a separate best spot from Smart Score data
- `index.html:842` the CTA still calls `generateSmartMoveRecommendation()`

**QA read:** same disagreement/trust issue still exists.

---

### 5. Narrow-phone bottom-sheet overlap risk
**Status:** NOT FIXED

The main control panel still becomes a bottom sheet under 399px, and the Top Blocks panel still becomes its own bottom sheet under 480px.

**Evidence**
- `index.html:486-490` control panel bottom-sheet rules keep `max-height: 60vh`
- `index.html:636-644` Top Blocks panel still becomes bottom-anchored with `max-height: 45vh`
- `index.html:4533` `showTopBlocksPanel()` still independently shows Top Blocks in Smart Score mode

**QA read:** the overlap/crowding failure mode is still structurally present on smaller phones.

---

### 6. `block_cleaned` still visually ages like generic short-lived reports
**Status:** NOT FIXED

`trackerAgeClass()` is unchanged. It still marks anything older than 10 minutes as `stale`, including `block_cleaned` reports that remain valid for the active ASP window.

**Evidence**
- `index.html:1363` `trackerAgeClass(report)` still returns `stale` after 10 minutes with no type-specific handling

**QA read:** the most useful tracker signal during active cleaning still fades visually too quickly.

---

### 7. Tile caching concern
**Status:** PARTIALLY IMPROVED, NOT RESOLVED

There is a real improvement here, but it does not solve the original problem.

**Improved**
- `sw.js` now avoids caching live Supabase traffic
- cache version bumped to `wepark-v6`

**Still unresolved**
- tile payloads are still explicitly `cache-first`
- tile refresh still depends on cache-version invalidation instead of revalidation/content hashing

**Evidence**
- `sw.js:104-118` still uses cache-first behavior for `tile_*.json`

**QA read:** this reduces tracker/backend cache risk, but tile-data freshness still depends on manual version discipline.

## Regression scan

### Park My Car
- No regression fix landed for the CTA or pin-to-block resolution.
- The parked-car core flow still depends on `findClosestSegment()` for pin mode, so the original wrong-block risk is still active.

### Tracker modal flow
- **No obvious new regression found in code review.**
- This branch is actually better in a few places:
  - auth gate copy/button state is provider-aware
  - `auth_required` now re-opens the gate instead of hard-failing
  - tracker refresh failures are handled more gracefully
- Important caveat: this was validated by static review/diff inspection, not browser automation, because the browser tool was unavailable during verification.

### Smart Move
- Still split between two ranking engines.
- Still inherits the future-ASP-suspension blind spot.
- No evidence that the QA issues in Smart Move were addressed.

### Smart Score
- Still uses today-only ASP suspension logic for current-time scoring.
- No evidence that future suspended cleaning days are skipped in the score/timing model.

### Mobile bottom-sheet behavior
- Still structurally at risk on narrow screens because both bottom sheets can exist simultaneously.
- I do not see any layout gate that forces one-sheet-at-a-time behavior.

## Bottom line
This branch should **not** be treated as having closed the QA findings from `TRACKER_QA_REVIEW.md`.

Best current summary:
- Resolved: **0**
- Partially improved: **1** (`sw.js` backend/cache plumbing only, not the original tile-freshness issue)
- Still open: **6 major findings**, including all three original High issues

## Method note
Verification was done by:
- reading `TRACKER_QA_REVIEW.md` from `tracker-qa-review`
- diffing `main..tracker-impl-v2`
- inspecting the current `index.html`, `sw.js`, and `tracker-config.js`

I attempted browser-based validation, but the OpenClaw browser tool was unavailable due gateway timeout, so this report is based on code-level QA verification rather than live UI automation.
