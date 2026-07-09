# TF2-17: Bottom-Card Chips Read "Free until X"

**Feature:** Restore per-restriction "Free until X" text on the Drive Mode bottom-card Left/Right chips when a side aggregates to free, without regressing the TF2-7 side-level aggregation or the FT-9 metered-ordering fix.
**Owner:** @ios-engineer (after Kevin approves this spec); @qa-verifier per pass.
**Created:** 2026-07-09
**Status:** SPEC — all open questions resolved with a recommendation; ready for engineering.

---

## Decisions Kevin Needs Before Engineering Starts

None are blocking. All resolved below with a recommendation — flagging up front per house style.

**OQ-1 (non-blocking): No-upcoming-restriction case.** When a side aggregates to free and **none** of its qualifying free segments has a restriction within the 14-day window, the chip keeps the current TF2-7 text: **"Free — check signs"** (no fabricated "until"). Rationale: the "check signs" qualifier exists because aggregation collapses multiple zones/segments into one chip — that caveat is equally true whether or not a restriction is coming. See §5.2.

**OQ-2 (non-blocking): Metered / restricted chip copy.** Stays **unchanged** this pass ("Metered" / "No parking"). Kevin's ask was specifically about the free case. Time-qualifying metered ("Metered until X") and restricted copy is a natural fit for the already-dispatched TF2-18 holistic design pass on the same view — flagged as an explicit follow-up, not silently bundled here. See §10.

**OQ-3 (non-blocking): Metered-free segments excluded from the "earliest restriction" ranking.** A segment that's currently free because its meter isn't running yet ("free until 9am") is **not** used to supply the chip's "until" text, even though it individually renders "free until 9am" via `meteredStatus`. Reason: `ParkingRulesEngine.nextRestriction()` already treats METERED as a fundamentally different category and explicitly skips it ("not a move-your-car restriction," `ParkingRulesEngine.swift:218-219`) — reusing that exact, already-battle-tested semantic for the ranking avoids inventing a new engine API and avoids any risk of a new FT-9-class ordering bug. See §5.1, §6.1.

**OQ-4 (non-blocking): Voice unchanged.** Confirmed structurally impossible to regress — `buildUtteranceText` and `CruiseVoicePolicy.utteranceText` read `SafetyLabel.severity`, never `.text`. A regression test locks this. See §6.2.

**OQ-5 (non-blocking): Truncation.** Rely on the existing `chipView` layout (`lineLimit(2)`, `minimumScaleFactor(0.75)`) — no layout change proposed. Verify via live-UI smoke with a worst-case fixture (full weekday name + `h:mm a` time, e.g. "Free until Wednesday 11:45 PM" — the longest string the engine can produce). If smoke reveals real clipping, that's layout work and belongs in TF2-18, not this spec. See §7 AC-12.

---

## 1. Problem and User Story

**Kevin's ask (build 13):** "wants the left/right readings to say 'Free until X'."

**History:** Pre-TF2-7, chips carried the engine's full per-segment label (e.g. "Free until Thu 9:30am") because each side mapped to exactly one segment's `safetyLabel`. TF2-7 introduced side-level aggregation (`DrivingContextService.aggregateSide` → `SideOpportunity`) to collapse zone-by-zone detail into one glanceable classification per side — but in doing so replaced the chip text with generic category copy: `"Free — check signs"` / `"Metered"` / `"No parking"` (`SafetyLabel(for: SideOpportunity)`, `Models/SafetyLabel.swift:58-69`). The underlying per-segment engine (`ParkingRulesEngine.safetyLabel(for:at:)`) still computes the exact "Free until X" text Kevin wants — it just isn't surfaced past the aggregation step anymore.

**User story:** "As a WePark driver, when the bottom card tells me a side is free, I want to know how long — 'Free until Thu 9:30 AM' is more useful than a bare 'Free.'"

**Why now:** Small, self-contained, no camera/#31 risk — a good next slice after TF2-16, and it prepares the ground for TF2-18's broader visual pass on the same card without blocking on it.

---

## 2. Scope — In / Out

### In
- iOS only.
- `DrivingContextService`: new `SideAggregation` struct + `aggregateSideDetail(...)`; `aggregateSide(...)` becomes a thin wrapper (unchanged public contract).
- `SafetyLabel`: new `init(for: SideAggregation)` (additive — existing `init(for: SideOpportunity)` untouched).
- `DriveModeBottomCard` preview only (realistic engine-formatted text, not the stale hand-typed "Thu 9:30am" abbreviation).
- Text/logic only. **No layout changes.**

### Out
- Metered/restricted chip copy changes (OQ-2 — follow-up, likely TF2-18).
- Meter-start-aware ranking (OQ-3 — would need a new `ParkingRulesEngine` accessor; out of scope).
- Voice/commentary changes (none needed — confirmed unaffected, OQ-4).
- Any `DriveModeBottomCard` body/layout/color/spacing change — that's TF2-18's territory. This spec is written so it can land **either standalone or bundled into the TF2-18 engineering PR** without conflict, because it touches no layout code (§4).
- Backend/tile/PWA changes.

---

## 3. Architecture

### Codebases touched
iOS only:
- `ios/WePark/WePark/Services/DrivingContextService.swift`
- `ios/WePark/WePark/Models/SafetyLabel.swift`
- `ios/WePark/WePark/Views/DriveModeBottomCard.swift` (preview literal only)
- `ios/WePark/WeParkTests/TF27Tests.swift` (extend) or a new `TF217Tests.swift`

PWA: no changes (the PWA never had this side-aggregation regression — TF2-7 was iOS-only). Backend: no changes.

### Current flow (today, post-TF2-7)

```
DrivingContextService.update()
  → aggregateSide(segments:side:engine:date:) -> SideOpportunity   // short-circuits on first qualifying free segment
  → SafetyLabel(for: SideOpportunity)                              // generic copy: "Free — check signs" / "Metered" / "No parking" / "—"
  → DrivingContext.leftLabel / rightLabel
  → DriveModeBottomCard chip renders SafetyLabel.text
```

`aggregateSide` (`DrivingContextService.swift:406-445`) already calls `engine.safetyLabel(for: seg, at: date)` per segment on the side and short-circuits to `.free` on the first qualifying (≥6m) free segment — it discards the segment's own "Free until X" text at that point.

### New flow

```
DrivingContextService.update()
  → aggregateSideDetail(segments:side:engine:date:) -> SideAggregation
       {
         opportunity: SideOpportunity           // SAME classification result as today (§5.1 preserves precedence)
         earliestFreeUntilText: String?         // NEW — nil unless opportunity == .free AND a qualifying
                                                 // segment has a real (non-metered) upcoming restriction
       }
  → aggregateSide(...) = aggregateSideDetail(...).opportunity   // thin wrapper, exact same public contract
  → SafetyLabel(for: SideAggregation)            // NEW init — text = earliestFreeUntilText ?? "Free — check signs"
                                                  //             (or unchanged "Metered"/"No parking"/"—" for other cases)
  → DrivingContext.leftLabel / rightLabel
  → DriveModeBottomCard chip renders SafetyLabel.text   // UNCHANGED view code
```

### New / changed symbols

**`DrivingContextService.swift`:**

| Symbol | Change |
|---|---|
| `struct SideAggregation: Equatable { let opportunity: SideOpportunity; let earliestFreeUntilText: String? }` | NEW. Lives next to `SideOpportunity`. |
| `static func aggregateSideDetail(segments:side:engine:date:minimumFreeLength:) -> SideAggregation` | NEW. Same traversal as today's `aggregateSide`, minus the early-return-on-first-free-segment shortcut — visits all qualifying (≥`minimumFreeLength`) free segments, ranks by `engine.nextRestriction(for:).hours` (excluding the sentinel `>= 168`), takes the minimum, and carries that segment's `SafetyLabel.text` forward. See §5.1. |
| `static func aggregateSide(segments:side:engine:date:minimumFreeLength:) -> SideOpportunity` | CHANGED internals only: now `aggregateSideDetail(...).opportunity`. **Signature, return type, and all 9 existing `TF27Tests` decision-table outcomes are unchanged** — this is a pure refactor for reuse, not a behavior change. |
| `update(...)` | The two call sites `leftOpp = ... aggregateSide(...)` / `rightOpp = ... aggregateSide(...)` become `leftAgg = ... aggregateSideDetail(...)` / `rightAgg = ... aggregateSideDetail(...)`; `SafetyLabel(for: leftOpp)` → `SafetyLabel(for: leftAgg)` (and right). No other change to `update()`. |

**`Models/SafetyLabel.swift`:**

| Symbol | Change |
|---|---|
| `init(for aggregation: SideAggregation)` | NEW, additive extension init. `.free` with `earliestFreeUntilText != nil` → that exact text, `.free` severity. `.free` with `nil` → `"Free — check signs"` (unchanged TF2-7 string), `.free` severity. `.metered` → `"Metered"` (unchanged). `.restricted` → `"No parking"` (unchanged). `.unknown` → `"—"` (unchanged). |
| `init(for opportunity: SideOpportunity)` | **Untouched.** Existing `SafetyLabelSideOpportunityTests` pass unmodified. |

**`Views/DriveModeBottomCard.swift`:**

| Symbol | Change |
|---|---|
| `#Preview` (line ~250-266) | `leftLabel` literal updated from the stale hand-typed `"Free until Thu 9:30am"` to a realistic engine-formatted example, e.g. `"Free until Wednesday 9:30 AM"` (matches `nextRestrictionTimeLabel`'s actual `"\(dayLabel) \(h:mm a)"` format — full weekday name, space before AM/PM). No other change to this file. |

### Tables / RPCs
None. Pure client-side.

---

## 4. Work Streams

Single iOS-only stream. Not #31-sensitive (no `MapViewRepresentable`/camera/MapKit code touched at all) — the full camera-path ceremony (RegionSyncGuardTests, mandatory live-UI smoke gate) does not apply, though a quick sim screenshot for AC-12 (text-length check) is still worth doing.

| Stream | Agent | Notes |
|---|---|---|
| `SideAggregation` + `aggregateSideDetail` + `aggregateSide` refactor + tests | @ios-engineer | Pure service-layer change, fully unit-testable. |
| `SafetyLabel(for: SideAggregation)` + tests | @ios-engineer | Additive. |
| `DriveModeBottomCard` preview update | @ios-engineer | Cosmetic, no body/layout diff. |
| QA pass (fresh agent) | @qa-verifier | `docs/qa/tf2-17-chip-free-until-pass-1-<date>.md`. |

**Bundling note:** this spec's diff footprint (`DrivingContextService.swift`, `SafetyLabel.swift`, one preview literal) does not overlap with `DriveModeBottomCard`'s body/layout code, so it can land as its own PR **or** be folded into the TF2-18 design-pass engineering PR without merge conflict — whichever the orchestrator prefers when TF2-18's designer review lands.

---

## 5. Decision Logic (Precise Behavior)

### 5.1 `aggregateSideDetail` — earliest-restriction ranking

```swift
static func aggregateSideDetail(
    segments: [Segment],
    side: String,
    engine: ParkingRulesEngine,
    date: Date,
    minimumFreeLength: Double = 6.0
) -> SideAggregation {
    let sideSegments = segments.filter { $0.side == side }
    guard !sideSegments.isEmpty else {
        return SideAggregation(opportunity: .unknown, earliestFreeUntilText: nil)
    }

    var hasMetered = false
    var qualifyingFree: [(seg: Segment, label: SafetyLabel)] = []

    for seg in sideSegments {
        let label = engine.safetyLabel(for: seg, at: date)
        switch label.severity {
        case .free:
            if segmentLengthMeters(seg) >= minimumFreeLength {
                qualifyingFree.append((seg, label))
            }
            // Sub-minimum free sliver: not actionable, excluded — same as today's aggregateSide.
        case .metered:
            hasMetered = true
        case .restricted, .unknown:
            break
        }
    }

    if !qualifyingFree.isEmpty {
        // OQ-3: nextRestriction() intentionally skips METERED rules (ParkingRulesEngine.swift:218-219)
        // — a "free until 9am" text driven by an upcoming meter start (not a real restriction) is
        // therefore excluded from this ranking. It still counts toward .free classification; it just
        // doesn't supply the "until" text unless some OTHER qualifying segment on the side has a
        // genuine upcoming restriction (ASP / No Parking / Truck Loading).
        var best: (hours: Double, text: String)? = nil
        for (seg, label) in qualifyingFree {
            let hours = engine.nextRestriction(for: seg, at: date).hours
            guard hours < 168 else { continue }   // no restriction within the 14-day window
            if best == nil || hours < best!.hours {
                best = (hours, label.text)
            }
        }
        return SideAggregation(opportunity: .free, earliestFreeUntilText: best?.text)
    }

    if hasMetered { return SideAggregation(opportunity: .metered, earliestFreeUntilText: nil) }
    return SideAggregation(opportunity: .restricted, earliestFreeUntilText: nil)
}

static func aggregateSide(segments:side:engine:date:minimumFreeLength:) -> SideOpportunity {
    aggregateSideDetail(segments: segments, side: side, engine: engine, date: date,
                         minimumFreeLength: minimumFreeLength).opportunity
}
```

Precedence (free > metered > restricted > unknown) is **identical** to today's `aggregateSide` — this is a full-scan refactor of the same algorithm, not a new decision. The only behavioral addition is `earliestFreeUntilText`.

**Mixed-side case** (some free zones, some metered/restricted on the same side) is therefore already handled: it resolves to `.free` (as it does today, TF2-7 precedence unchanged), with the earliest-restriction text (or the check-signs fallback) computed from the qualifying free segments only. No new branch needed.

### 5.2 `SafetyLabel(for: SideAggregation)`

```swift
extension SafetyLabel {
    init(for aggregation: SideAggregation) {
        switch aggregation.opportunity {
        case .free:
            self.init(text: aggregation.earliestFreeUntilText ?? "Free — check signs", severity: .free)
        case .metered:
            self.init(text: "Metered", severity: .metered)
        case .restricted:
            self.init(text: "No parking", severity: .restricted)
        case .unknown:
            self.init(text: "—", severity: .unknown)
        }
    }
}
```

`aggregation.earliestFreeUntilText` reuses `engine.safetyLabel(for:).text` **verbatim** — whatever exact string the engine produces for that segment (e.g. `"Free until Wednesday 9:30 AM"` from the ASP/No-Parking/Truck-Loading branch) flows through unchanged. This spec does not reformat, re-case, or otherwise touch the engine's text output — it only selects *which* segment's text to surface.

---

## 6. Analysis

### 6.1 Why this does not reintroduce the FT-9 bug class

FT-9 (`docs/qa/ft9-bowery-2ndave-investigation.md`) was a branch-ordering bug **inside** `ParkingRulesEngine.safetyLabel(for:at:)` — the metered-active-now check ran *after* the "upcoming ASP → Free until X" branch, so an actively-metered segment could incorrectly report `.free`. This spec never reimplements or reorders any of that logic: `aggregateSideDetail` calls `engine.safetyLabel(for: seg, at: date)` exactly once per segment, exactly as `aggregateSide` does today, and switches on `.severity` exactly as today. The FT-9 fix (metered-check-before-free-check, `ParkingRulesEngine.swift:96-117`) is fully inherited automatically — this spec adds a *ranking* step over segments the engine has already correctly classified as `.free`, it does not touch classification. A named regression test (Test Inventory #9) replays the exact FT-9 scenario at the aggregation level to lock this.

### 6.2 Why voice is provably unaffected (OQ-4)

`DrivingContextService.buildUtteranceText(_:)` (`DrivingContextService.swift:344-376`) and `CruiseVoicePolicy.utteranceText(for:)` both branch on `context.leftLabel.severity` / `.rightLabel.severity` — never on `.text`. Since this spec changes only `SafetyLabel.text` for the `.free` case (severity is unchanged in every case), voice output is structurally incapable of changing. Test Inventory #10 locks this with an explicit assertion.

### 6.3 Chip text length

Worst case: `"Free until "` (11 chars) + full weekday name (up to `"Wednesday"`, 9 chars) + `" "` + `"11:45 PM"` (8 chars) = **"Free until Wednesday 11:45 PM"**, 30 characters. The existing `chipView` (`DriveModeBottomCard.swift:153-173`) already uses `.lineLimit(2)` + `.minimumScaleFactor(0.75)` at `.subheadline` in a ~half-card-width chip — designed with headroom for exactly this kind of string (the pre-TF2-7 chips already showed this format routinely). No layout change is proposed; AC-12 requires a live-UI smoke check with this exact worst-case string to confirm no visual clipping before merge, and if it *does* clip, that's a layout fix routed to TF2-18, not blocking this spec's text/logic change.

---

## 7. Acceptance Criteria

- [ ] **AC-1.** `SideAggregation` struct + `DrivingContextService.aggregateSideDetail(...)` implemented per §5.1. `aggregateSide(...)` is a thin wrapper with its exact existing signature/return type preserved.
- [ ] **AC-2.** All 9 existing `TF27Tests` `aggregateSide` decision-table tests pass **unmodified**.
- [ ] **AC-3.** `SafetyLabel(for: SideAggregation)` implemented per §5.2. Existing `SafetyLabel(for: SideOpportunity)` init and `SafetyLabelSideOpportunityTests` are untouched.
- [ ] **AC-4.** `DrivingContextService.update()` constructs `leftLabel`/`rightLabel` via `SafetyLabel(for: SideAggregation)`.
- [ ] **AC-5.** Free side with a qualifying (≥6m) segment that has an upcoming ASP/No Parking/Truck Loading restriction within 14 days → chip text is byte-identical to that segment's `engine.safetyLabel(for:).text` (e.g. `"Free until Wednesday 9:30 AM"`).
- [ ] **AC-6.** When multiple qualifying free segments on a side have different upcoming restrictions, the chip shows the **earliest** one (smallest `nextRestriction.hours`) — conservative-min per Kevin's direction.
- [ ] **AC-7.** Free side where no qualifying segment has any restriction within 14 days → chip text is `"Free — check signs"` (unchanged from TF2-7) — no fabricated "until".
- [ ] **AC-8.** Metered-only side and restricted-only side chip text is unchanged from today (`"Metered"` / `"No parking"`).
- [ ] **AC-9.** Mixed-side (free + metered/restricted on the same side) still resolves to the free-branch text per AC-5/AC-7 — precedence unchanged from TF2-7.
- [ ] **AC-10.** A metered-free segment ("free until 9am" via `meteredStatus`, no other restriction category on the side) does **not** supply the earliest-restriction text — the side falls back to AC-7's "Free — check signs" unless another qualifying segment has a genuine restriction.
- [ ] **AC-11 (FT-9 regression).** A side with an actively-metered-now segment (severity `.metered`) plus a different segment with an upcoming ASP still classifies the side as `.metered` overall (not `.free`) if no OTHER segment qualifies free — engine severity ordering is provably untouched.
- [ ] **AC-12 (live-UI smoke).** Sim screenshot with a constructed worst-case fixture (`"Free until Wednesday 11:45 PM"`, 30 chars) shows no visual clipping in the chip within the existing `lineLimit(2)` / `minimumScaleFactor(0.75)` layout.
- [ ] **AC-13.** `buildUtteranceText` and `CruiseVoicePolicy.utteranceText` output is byte-identical before/after this change (locked by Test Inventory #10).
- [ ] **AC-14.** `DriveModeBottomCard` preview updated to a realistic engine-formatted "Free until X" string; no other diff to that file.
- [ ] **AC-15.** Full test suite green; @ios-engineer reports the exact before/after count in the PR.
- [ ] **AC-16.** Independent QA pass (`@qa-verifier`, not the builder) filed at `docs/qa/tf2-17-chip-free-until-pass-1-<date>.md` before merge.

---

## 8. Test Inventory

**Extend `TF27Tests.swift`** (or new `TF217Tests.swift` alongside it):

1. `testAggregateSideDetail_singleFreeSegmentWithUpcomingASP_returnsFreeUntilText` — text byte-identical to `engine.safetyLabel(for:).text`.
2. `testAggregateSideDetail_multipleFreeSegments_earliestRestrictionWins` — two qualifying free segments (restrictions in 2h and 6h) → text reflects the 2h one.
3. `testAggregateSideDetail_allFreeSegmentsUnrestricted_returnsNilText` → `SafetyLabel(for:)` renders `"Free — check signs"`.
4. `testAggregateSideDetail_meteredFreeSegmentOnly_excludedFromRanking_fallsBackToCheckSigns` — OQ-3 nuance test.
5. `testAggregateSideDetail_mixedFreeAndRestrictedSegments_stillReturnsFreeWithText` — precedence unchanged.
6. `testAggregateSideDetail_subMinimumFreeSegment_excludedFromRanking` — a sub-6m free sliver with an earlier restriction must NOT win the ranking over a longer qualifying segment with a later one.
7. `testAggregateSideDetail_matchesAggregateSideOpportunity_forAllNineExistingDecisionTableCases` — regression parity: same `SideOpportunity` output as the current 9 `aggregateSide` cases.
8. `testAggregateSide_publicWrapper_unchangedAfterRefactor` — explicit assertion that `aggregateSide` still returns the same enum values as `aggregateSideDetail(...).opportunity`.
9. `testAggregateSideDetail_ft9Regression_activelyMeteredSegmentPlusUpcomingASP_classifiesMetered` — replays the FT-9 Bowery/2nd-Ave scenario at the aggregation level; asserts `.metered`, not `.free`.

**`SafetyLabelSideAggregationTests` (new, or extend `SafetyLabelSideOpportunityTests`):**
10. `.free` with text → exact text, `.free` severity.
11. `.free` with nil text → `"Free — check signs"`, `.free` severity.
12. `.metered` → `"Metered"`, `.metered` severity (unchanged).
13. `.restricted` → `"No parking"`, `.restricted` severity (unchanged).
14. `.unknown` → `"—"`, `.unknown` severity (unchanged).

**Voice regression:**
15. `testBuildUtteranceText_unaffectedBySafetyLabelTextChange` — construct two `DrivingContext`s with identical severities but different `.text` (old generic vs. new "until X") → assert `buildUtteranceText` output is identical. Same idea for `CruiseVoicePolicy.utteranceText` if it has its own test file.

**Not unit-testable (smoke/manual only):**
16. Chip text-length/clipping check with the 30-character worst-case fixture (AC-12) — sim screenshot, read it.

**Regression gate:**
17. Full `xcodebuild test` suite green; net count increase reported in PR (≈ +15 new tests per above).

---

## 9. Open Decisions (Summary)

| ID | Question | Resolution | Blocks |
|---|---|---|---|
| OQ-1 | No-upcoming-restriction free chip text? | `"Free — check signs"` (unchanged, no fabricated "until"). | Nothing. |
| OQ-2 | Time-qualify metered/restricted chip copy too? | **No**, unchanged this pass — deferred to TF2-18. | Nothing. |
| OQ-3 | Include metered-free (meter-not-charging) segments in the earliest-restriction ranking? | **No** — inherits the engine's own METERED-exclusion semantic; would need a new engine accessor to do otherwise. | Nothing. |
| OQ-4 | Does voice copy change? | **No** — structurally impossible to regress (severity-driven, not text-driven); locked by a regression test. | Nothing. |
| OQ-5 | Chip truncation risk? | Rely on existing layout; verify via smoke with worst-case fixture; any real clipping routes to TF2-18. | Nothing. |

No item in this table blocks engineering start.

---

## 10. Out-of-Scope Follow-Ups

- **Metered / restricted "until X" chip copy** (e.g. "Metered until 7pm", "No parking until 9am") — natural fit for TF2-18's holistic bottom-card pass; not bundled here to keep this PR small and low-risk.
- **Meter-start-aware ranking** — folding metered-free segments into the earliest-restriction search would require a small new `ParkingRulesEngine` accessor (e.g. `hoursUntilMeterStart(for:at:)`); deferred, only worth doing if Kevin specifically wants meter-start urgency reflected in the aggregate chip.
- **Any `DriveModeBottomCard` layout/color/spacing change** — explicitly out of scope; this spec touches text/logic only, precisely so it can land independently of or bundled with TF2-18 without conflict.

---

## 11. Related Specs and Docs

- `docs/tf2-7-cruise-guidance-spec.md` — introduced side-level aggregation and the generic chip copy this spec restores detail to.
- `docs/qa/ft9-bowery-2ndave-investigation.md` — the metered-ordering bug class this spec must not reintroduce (§6.1).
- `docs/field-testing-log.md` — TF2-17 entry (source of this spec's direction); TF2-18 entry (the related holistic design pass this spec is written to coexist with).
- `ios/WePark/WePark/Services/ParkingRulesEngine.swift` — `safetyLabel(for:at:)` (text source, unmodified) and `nextRestriction(for:at:)` (ranking source, unmodified).
