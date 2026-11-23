# PR #153 QA — AX dock follow-ups (banner chip, coach region at AX5, rail clearance) — 2026-11-23

**Reviewed:** branch `fix/ax-dock-followups` at `f6760b60`, against `docs/design/goal-first-ambient-design.md` (Amendment: AX dock as built, §3) and `docs/qa/pr152-ax-goal-dock.md`
**Verdict:** MERGE (✅ ship it). 0 blocking, 0 significant, 3 minor polish notes.

## Summary
The chip fixes both PR #152 banner findings: dock measured at 35–42% with a chip (was 49–59%), and the "Park here?" card now sits clear above the dock at AX1–AX5 with every chip/banner string readable and the card buttons tappable. Coach marks 1 and 2 at AX5 (cold, mid-coach switch from AX3, and with a chip showing) no longer collide with the ASP banner, Skip, Start Driving or the rail, and the body scrolls with Got it pinned. Rail clearance and the `.large` detent at AX4+ verified live. Not reached live: `.steppedDown` / `.sparse` chip kinds (see Out of scope).

Method: iPhone 17 smoke sim (402x874 pt), flags flipped locally (`driveModeDefaultEnabled`, `onboardingStoryEnabled`) and discarded; AXe `describe-ui` frames + screenshots read. Local edits reverted before commit.

## Measured budget (own measurements, `.empty` chip, Park & Forget, dock = 874 − chip top)
| Size | Chip top | Dock pt | Dock % | Limit | Chip height | PR #152 (full banner) |
|---|---|---|---|---|---|---|
| AX1 | 507 | 367 | 42.0% | ≤45% | 44 | 50% |
| AX2 | 555 | 319 | 36.5% | ≤45% | 44 | 59% |
| AX3 | 568 | 306 | 35.0% | ≤45% | 44 | 49% |
| AX5 | 568 | 306 | 35.0% | ≤45% | 44 | 49% |

All four match the PR body's table exactly. AX4 not measured separately (same layout as AX3/AX5 per code; sheet checked at AX4).

## PR #152 findings status
| #152 finding | Status | Evidence |
|---|---|---|
| 🟡 #1 banner budget (dock over limit) | FIXED | LIVE: table above, all ≤45% |
| 🟡 #2 "Park here?" card covering banner | FIXED | LIVE: card bottom vs chip top — AX1 479/507, AX2 527/555, AX3 540/568, AX5 540/568; both buttons tappable (tapped Park here at AX2, it advanced to the Park my car sheet) |
| 🟡 #3 coach mark 2 overflow at AX5 | FIXED | LIVE: cold AX5 marks 1+2, AX3→AX5 switch, and with chip showing |
| 🟢 #4 bubble covers More/Recenter | FIXED | LIVE: AX3 bubble right 321.6 ≤ rail left 330 − 8 = 322; AX5 same |
| 🟢 #5 medium detent shows one tile at AX4+ | FIXED | LIVE: grabber y=57 (large) at AX4 and AX5; y=410 (medium) at AX1 and AX3 |

## Acceptance checklist (LIVE = driven on sim, CODE = read only)
- [x] Chip one line, right string, icon + chevron, ≥44pt at AX1/2/3/5 — LIVE ("No clear spots nearby", `Remove Map Pin` icon, `Forward` chevron, height 44)
- [x] Dock ≤45% — LIVE (table)
- [x] Chip tap opens goal sheet, first row = full sentence + icon — LIVE (AX1 screenshot read; AX4/AX5 frames show the full sentence row first)
- [x] AX2 + chip drops "Change"; AX1 + chip keeps it — LIVE (AX2 screenshot shows chevron only; AX1 shows Change)
- [x] `large` flags-on: full-sentence banner, non-interactive, unchanged — LIVE (screenshot read)
- [x] "Park here?" card with chip showing AX1–AX5 — LIVE
- [x] Coach 1+2 cold AX5: Skip at y=207 below 203pt banner, bubble 301→~620, right edge 322, Got it pinned, body scrolls — LIVE
- [x] Coach AX3 cold then switch to AX5 mid-coach: Skip/bubble re-layout correctly, no stale frames — LIVE
- [x] Coach mark 2 with chip showing at AX5 (goal Park & Forget picked during coach): bubble 301→556, chip top 568, clear — LIVE
- [x] Rail clearance AX3/AX5 — LIVE
- [x] Sheet detent: large AX4+, medium below — LIVE
- [x] PR #152 regression: card → sheet → pick dismisses and applies; Done and swipe-down leave selection unchanged and coach bubble returns; Manhattan map recolors after pick — LIVE (Manhattan 40.7506,-73.9935)
- [x] Flags off: legacy UI (Report / Map key / Park Until / Parking 101, no goal dock) — LIVE (rebuilt flags-off, launched, frames read)
- [x] New ASP-banner / rail observers add no `mapZStack` child: both are `.onGeometryChange` modifiers on existing views — CODE
- [x] Stale/zero frames: `topChromeBottom=0` / `railFrame=.zero` defaults are no-ops (`max(legacy, …)`, `.zero` guard) — CODE; first layout + size change observed live — LIVE
- [x] Flag-off: observers still run and write two `@State` values, but the coach overlay (only reader) is not mounted; functionally inert — CODE
- [x] Helpers in `OnboardingCoachModel.swift` are `nonisolated` pure functions; `hardFloor` 140 fallback grows region only when AX region <140pt (cannot occur on a 874pt screen; not exercised) — CODE
- [x] Chip gated on `usesGoalCard` (AX and not full-palette) via `goalDockUsesBannerChip` — CODE; below AX1 confirmed LIVE
- [x] No change below AX1: all new behavior keyed on AX layout (`goalCardLayout` / `usesGoalCard`); legacy `else` branches preserved — CODE + LIVE (`large`)

## Findings

### 🔴 Blocking
None.

### 🟡 Significant
None.

### 🟢 Minor / nit
- **#1: Coach body is mostly scroll at AX5 with a chip showing**
  - Where: coach mark 2, AX5, chip showing (`OnboardingCoachOverlay.bubbleRegion`)
  - What: region is 301→556 (255pt); Got it takes 73pt, leaving ~1.7 lines of body visible ("Green means you're…" cut mid-line). Without a chip, ~2.5 lines. Body is scrollable and Got it is pinned, so it is usable and matches the PR's stated design, but first impression is a clipped sentence.
  - Expected: spec allows scroll; consider a scroll hint or a tighter title at AX5 if design cares.
  - Owner: `@ios-engineer` / `@designer`, optional.
- **#2: Goal sheet banner row is 369pt tall at AX5**
  - Where: `GoalPickerSheet` banner row (uncapped Dynamic Type by spec)
  - What: first tile begins at y=521 at AX5 (large detent), so one tile is visible without scrolling. Spec-intended (full sentence at the sheet's own size); noting for polish.
  - Owner: `@ios-engineer`, optional.
- **#3: Skip pill sits over the Apple Park/POI map label at AX5**
  - Where: coach overlay, AX5
  - What: Skip is correctly below the 203pt banner but overlaps a map POI label ("…PARK"). Cosmetic, map content only. (ASP banner overlapping the Search button at AX5 is the known out-of-scope item.)
  - Owner: none required.

### 💡 Out of scope (logged, not fixed)
- `.steppedDown` / `.sparse` chip kinds NOT reached live. Tried Park & Forget at four Manhattan edge locations (Inwood, Battery river edge, Washington Heights, East River); the guard never fired, likely needs a map pan. Covered by `testBudget_withBannerChip…` (all kinds, goals, AX1–5) and `testChipCopy_perKind…`; copy strings are in code only. Recommend a one-off live check on the device when convenient.
- ASP banner overlapping Search at AX5, and "Can-cel" wrap in the Park here card at AX5 (both noted in PR body as out of scope; both visible in screenshots).
- Not run: full test suite (CI green per dispatch); VoiceOver reading of the chip (label/hint/trait verified in code only: label = full sentence, hint "Opens goal options", `.isButton`).

## Smoke tests run
Build once flags-on (derived data in `~/Library/Caches`), rebuilt flags-off. Sim at Apple Park (no data) for chip/coach; Manhattan for recolor. All screenshots read. Derived data deleted, sim shut down, content size reset to `large`, onboarding keys cleared.

## What's working
The chip is a clean, big-target solution and the measured numbers match the PR body to the point. Frame-driven Skip/region math adapts live to a Dynamic Type switch mid-coach with no stale layout. Rail clearance lands within 0.4pt of the 8pt gap. PR #152's verified flows (card → sheet → pick/Done/swipe, coach return, recolor) show no regression.
