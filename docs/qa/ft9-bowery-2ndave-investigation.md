# FT-9: Bowery / 2nd Avenue "FREE parking" Misclassification
## Investigation Report — 2026-06-08

**Filed:** Kevin field-test, real device, daytime, 2026-06-08  
**Reporter:** backend-data investigation  
**Status:** Root cause confirmed; fix NOT yet applied.

---

## 1. Executive Summary

**Root cause: Hypothesis 1 — engine misclassifies METERED-active segments as FREE.**

Specifically, `safetyLabel(for:at:)` (iOS) and its exact source `actionableSafetyLabel(seg)` (PWA) both contain a branch-ordering defect: the "upcoming ASP restriction → free until X" branch fires and returns `.free` BEFORE the code can reach the METERED paid-hours check. Any segment that has METERED rules AND an upcoming ASP restriction (or NO_PARKING scheduled for a future window) will report `.free` severity during paid metered hours instead of `.metered`.

The map polyline color (driven by `currentState(for:at:)`, a separate code path) is NOT affected — it correctly returns `.meteredActive` (amber) for the same segment. The bug surfaces in:
- The Drive Mode bottom card chip (Left/Right severity chips in `DriveModeBottomCard.swift`)
- The `BlockDetailView` safety label text
- The Drive Mode voice commentary text (reads the safetyLabel text)

The PWA has the same bug (it is the source). The iOS port faithfully reproduced it.

---

## 2. Tile Data Baseline

### 2.1 Bowery

| Metric | Value |
|---|---|
| Total segments | 105 |
| Empty-rules segments | 0 |
| Segments with E side | 55 |
| Segments with W side | 50 |
| Rules with METERED | 19 |
| Rules with NO_STANDING | 42 |
| Rules with ASP_OVERNIGHT_MWF | 15 |
| Rules with ASP_OVERNIGHT_TTHS | 12 |
| Rules with ASP_DAILY | 8 |
| Rules with NO_PARKING | 7 |
| Rules with TRUCK_LOADING | 2 |

Bowery has no blocks where BOTH E and W sides appear in the dataset — each block has only one side. This is consistent with the street being one-way southbound (each block face has regulated parking on one side only, or the opposite side is entirely no-standing). No empty-rules segments.

Unique block/side combinations with METERED rules:
- `BOWERY, BLEECKER ST → E HOUSTON ST, W` — METERED 8AM-6PM Mon-Fri (commercial vehicles only)

### 2.2 2nd Avenue

| Metric | Value |
|---|---|
| Total segments (all tiles) | 671 |
| Empty-rules segments checked (LES area tiles) | 0 |
| Typical E-side rule | NO_STANDING ANYTIME (bus stops, commercial zones) |
| Typical W-side rule | METERED 9AM-10PM + ASP_DAILY 8:30-9AM |

Sample segment from `tile_10_13.json`:
```json
{
  "id": "2ND_AVENUE_EAST_3RD_STREET_EAST_2ND_STREET_W_3",
  "street": "2ND AVENUE", "from": "EAST 3RD STREET", "to": "EAST 2ND STREET", "side": "W",
  "rules": [
    {"category":"ASP_DAILY","days":[1,2,3,4,5,6],"timeRanges":[{"start":510,"end":540}]},
    {"category":"METERED","days":[1,2,3,4,5,6],"timeRanges":[{"start":540,"end":1320}]}
  ],
  "dominantCategory": "METERED"
}
```
The E-side for the same block (`2ND_AVENUE_EAST_3RD_STREET_EAST_2ND_STREET_E_3`) has `NO_STANDING ANYTIME` — correctly classified as `.restrictedNow` regardless of time.

Similarly for `tile_10_13.json`:
- `2ND_AVENUE_EAST_2ND_STREET_EAST_1ST_STREET_W_0`: ASP_DAILY 8:30-9AM + METERED 9AM-10PM
- `2ND_AVENUE_EAST_2ND_STREET_EAST_1ST_STREET_E_0/E_1`: NO_STANDING ANYTIME

The W-side (west curb) of 2nd Ave in the East Village consistently has the ASP_DAILY + METERED pattern.

---

## 3. Hypothesis Verdicts

### H1: Engine misclassifies METERED-active as FREE — CONFIRMED (primary root cause)

### H2: Per-side coverage gap — NOT THE PRIMARY CAUSE

All checked segments have non-empty rules. No empty-rules segments found on Bowery (0/105) or 2nd Ave (0 in LES tiles). Both E and W sides are present for 2nd Ave. Bowery has only one side per block, which is the expected real-world condition for a one-way street with parking on one curb only. Side coverage is not the cause.

### H3: Side/arrow mismatch — NOT CONFIRMED

The `arrow` field is used for directional sign splitting during tile build (not a runtime display concern). Runtime coloring uses the segment's `side` field directly. The side/arrow relationship does not affect which segment gets which color.

### H4: Time-window edge / gap between rules — NOT THE PRIMARY CAUSE

For the ASP_DAILY + METERED pattern (e.g., ASP_DAILY 8:30-9AM, then METERED 9AM-10PM): these rules are designed to be adjacent with no gap. At any moment from 9AM onward, METERED is active. The time-window analysis shows no uncovered "free" minutes during normal daytime hours. The apparent "free" classification is a code defect, not a genuine gap in the rule data.

---

## 4. Root Cause — Exact Code Path

### 4.1 The defective function

**iOS:** `ParkingRulesEngine.safetyLabel(for:at:)` in  
`/ios/WePark/WePark/Services/ParkingRulesEngine.swift`, lines 67–121.

**PWA (source):** `actionableSafetyLabel(seg)` in  
`/index.html`, lines 5457–5498.

Both are identical in logic. The iOS code is a faithful port of the PWA defect.

### 4.2 Trace at 1:00 PM on a weekday (Wednesday, day=3, minute=780)

**Segment:** `2ND_AVENUE_EAST_3RD_STREET_EAST_2ND_STREET_W_3`  
Rules: `[ASP_DAILY 8:30-9AM (510-540, days 1-6), METERED 9AM-10PM (540-1320, days 1-6)]`

**Step 1 — `nextRestriction(for:at:)` call:**

The function loops over rules:
- `ASP_DAILY` category: `isASP = true`. Active now? `isScheduleActive`: day=3 in days [1-6], timeRange 510-540, minute=780 → 780 NOT in [510, 540) → NOT active. Calls `computeHoursUntilASP`. Next occurrence: tomorrow 8:30 AM ET → approx 19.5 hours. Updates `soonestHours = 19.5`.
- `METERED` category: `if cat == .metered { continue }` (line 194-195). **Explicitly skipped.**

Returns `NextRestriction(hours: 19.5, label: "ASP Daily", category: .aspDaily, rule: ASP rule)`.

**Step 2 — Back in `safetyLabel`, line 77:** `restriction.isActiveNow` = false. Does not return here.

**Step 3 — `safetyLabel`, lines 97-100 (THE DEFECT):**
```swift
if restriction.hours < 168 {            // 19.5 < 168 → TRUE
    if let cat = restriction.category, cat.isASP {  // .aspDaily.isASP == true → TRUE
        let timeLabel = nextRestrictionTimeLabel(hours: 19.5, now: now)
        return SafetyLabel(text: "Free until Tomorrow 8:30 AM", severity: .free)
        // ↑ RETURNS HERE. Never reaches METERED check at line 110.
    }
}
```

The function returns `SafetyLabel(text: "Free until Tomorrow 8:30 AM", severity: .free)`.

**The METERED paid-hours check (lines 110-117) is never evaluated:**
```swift
if dom == .metered || rules.contains(where: { $0.category == .metered }) {
    let lbl = meteredStatus(for: segment, at: now)
    // Would return "Metered (paid until 10pm)" → stripped "paid until 10pm" → severity: .metered
    // But this code is never reached when an ASP restriction is scheduled.
}
```

### 4.3 Contrast: `currentState(for:at:)` — CORRECT

The map polyline color function (`/ios/WePark/WePark/Services/ParkingRulesEngine.swift`, lines 292-328) does NOT short-circuit for ASP:

```swift
func currentState(for segment: Segment, at now: Date) -> CurrentState {
    let restriction = nextRestriction(for: segment, at: now)
    // restriction.hours = 19.5h, category = .aspDaily

    if restriction.isActiveNow { return .restrictedNow }
    // → false, skip

    if restriction.hours < ParkingRulesEngine.nearFutureWindow / 3600.0 {
        // 19.5 < 6 → FALSE. Skip.
    }

    // Metered check runs unconditionally if any metered rule exists:
    let dom = segment.dominantCategory ?? dominantCategory(rules: rules)  // .metered
    if dom == .metered || rules.contains(where: { $0.category == .metered }) {
        let isMeteredNow = meterRules.contains { rule in
            // METERED 540-1320, day 3 in days [1-6]: minute=780 ∈ [540, 1320] → true
        }
        if isMeteredNow { return .meteredActive }  // ← CORRECT: returns amber
    }
    return .freeComfortably
}
```

`currentState` correctly returns `.meteredActive`. The map polyline is correctly amber.

### 4.4 Where the wrong value is consumed

| Surface | Function used | Result at 1 PM | Correct? |
|---|---|---|---|
| Map polyline color | `currentState` → `.meteredActive` | Amber | YES |
| BlockDetailView severity band (6pt strip) | `currentStateColor` → `.meteredActive` | Amber | YES |
| **BlockDetailView label text** | **`safetyLabel` → "Free until Tomorrow 8:30 AM"** | **GREEN text** | **NO** |
| **Drive Mode chip color** | **`safetyLabel.severity = .free`** | **Green chip** | **NO** |
| **Drive Mode chip text** | **`safetyLabel.text = "Free until Tomorrow 8:30 AM"** | **"Free until…"** | **NO** |
| **Drive Mode voice** | **`safetyLabel.text` read aloud** | **"Free until…"** | **NO** |

Kevin's field observation ("FREE on the LEFT side") most likely refers to the Drive Mode chip (and/or BlockDetailView label) showing GREEN and the text "Free until Tomorrow 8:30 AM" — while the map polyline itself is amber.

---

## 5. Systemic Scope

This is NOT an isolated Bowery/2nd Ave issue. It affects every segment in the tile dataset that has METERED rules combined with any future-scheduled ASP or NO_PARKING restriction.

**Scale indicators:**
- 13,795 METERED rule instances across 641 of 1,027 tiles (62% of all tiles)
- Any metered commercial district block that also has ASP street cleaning is affected
- In the East Village / LES area: virtually every block with METERED also has ASP_DAILY (the 8:30-9AM street-cleaning slot is nearly ubiquitous on metered commercial streets)
- Result: **for the entire paid-hours window (9AM-10PM Mon-Sat) on these blocks, the Drive Mode chip, BlockDetailView text label, and voice all say "Free until [ASP time]"** while charging a meter

The map polyline (amber) is correct and does NOT propagate the wrong classification. But the two highest-visibility text surfaces in the app — Drive Mode chips and BlockDetailView — do.

---

## 6. Fix Recommendation

### 6.1 The fix

In `safetyLabel(for:at:)` (iOS) and `actionableSafetyLabel(seg)` (PWA), add a METERED paid-hours check **before** the "free until ASP" branch. The intent is: if the meter is running right now, that is the most relevant fact for the user — regardless of what future restrictions are scheduled.

**Fix logic (pseudo-code, language-agnostic):**

```
// NEW: check metered paid-hours FIRST, before ASP "free until" branch
if segment has METERED rules:
    if meterIsActiveNow(segment, now):
        return SafetyLabel(text: meteredStatus(segment, now), severity: .metered)

// EXISTING (unchanged): ASP / NO_PARKING restriction active now → red
if restriction.isActiveNow:
    ...

// EXISTING (unchanged): ASP / NO_PARKING restriction coming → "Free until X"
if restriction.hours < 168 and restriction.category.isASP:
    ...

// EXISTING (unchanged): METERED during free hours → "free until 9am"
if segment has METERED rules:
    return meteredStatus with severity based on "paid until" vs "free until"
```

The metered-free-hours case ("free until 9am") still falls through to the existing METERED check at the bottom, which already handles it correctly. Only the metered-paid-hours case needs to be promoted to before the ASP branch.

**Alternatively** (simpler): move the entire existing METERED block (lines 110-117 in Swift, lines 5488-5493 in JS) to BEFORE the "upcoming ASP → free until" block. After this reorder, the control flow becomes:

1. Active NO_STANDING/NO_PARKING/etc → red (unchanged)
2. **METERED active now → "paid until X" / severity .metered (MOVED UP)**
3. Upcoming ASP/NO_PARKING → "Free until X" / severity .free (only reached if meter is not running)
4. METERED during free hours → "free until Xam" / severity .free (unchanged fallback)
5. No restrictions → "Free" (unchanged)

### 6.2 Fix location and owner

| Location | File | Owner |
|---|---|---|
| iOS | `ios/WePark/WePark/Services/ParkingRulesEngine.swift`, `safetyLabel(for:at:)`, lines 96-121 | `@ios-engineer` |
| PWA | `index.html`, `actionableSafetyLabel(seg)`, lines 5457-5498 | `@pwa-maintainer` |

**Tile data:** No tile data change required. The rules are correct. This is a pure engine/classification fix.

**Schema:** No backend schema change required.

**Both clients must be updated.** The iOS fix is the priority (TestFlight is live). The PWA fix should follow in the same PR or the next one to maintain parity.

### 6.3 Test additions required

The fix must include a new parity test case in `ParkingRulesEngineParityTests.swift`:

```
Segment: ASP_DAILY (8:30-9AM) + METERED (9AM-10PM)
Time: Wednesday 1:00 PM ET (day=3, minute=780)
Expected safetyLabel.severity: .metered
Expected safetyLabel.text: "paid until 10pm"
Expected currentState: .meteredActive  (already correct — regression guard only)
```

Also test the boundary:
```
Time: 9:00 AM ET exactly (start of metered hours, end of ASP window)
Expected: severity .metered, NOT .free
```

And the free-hours case (must not regress):
```
Time: 8:00 AM ET (before 9AM, meter not running, ASP 8:30-9AM upcoming in 30 min)
Expected: severity .free (OR .restricted if ASP is considered "soon" — confirm intent)
```

### 6.4 Does this need a spec?

No new spec needed. The fix is a straightforward branch-ordering correction that aligns `safetyLabel` with the product intent already stated in `docs/design/ios-mvp-palette.md` §2.2 and `docs/ios-mvp-spec.md` §3.7: metered-active should show the `.metered` color / severity, not free. The fix does not change product behavior for any other category.

---

## 7. Safety Notes

1. **This is systemic.** Any metered block with an ASP street cleaning rule (the most common configuration on NYC commercial streets) displays incorrectly. In the East Village / LES area this includes virtually every W-side segment of 2nd Avenue from at least E Houston to E 6th Street, plus the METERED blocks on Bowery W-side.

2. **The map polyline is NOT wrong.** Only the text/chip surfaces are affected. Users who rely on the amber polyline color can still correctly identify a metered block. Users who rely on the Drive Mode chip text or BlockDetailView label text are misled.

3. **Voice commentary is wrong.** In Drive Mode, the service reads `safetyLabel.text` aloud. A user would hear "Free until Tomorrow 8:30 AM" for a block where the meter is currently running. This is the highest-severity surface because the user is driving and may act on voice alone.

4. **Fix scope is narrow and safe.** Reordering the METERED check above the ASP check has no effect on segments that are purely ASP (no METERED rules) — those fall through the METERED check unchanged. It has no effect on the map polyline color. The change is surgical.
