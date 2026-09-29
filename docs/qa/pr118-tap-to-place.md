# QA Report: PR #118 — tap-to-place refinement + display-time curb-snap (#22)

**Reviewed:** `ios/report-tap-to-place` @ 4f3f67fc, base 6d654fc5, vs `docs/report-tap-to-place-spec.md`. Static-only (no toolchain).
**Verdict: MERGE-PENDING-MAC-GATE** — zero blocking defects; two 🟡 to fix pre-gate; default (no-reposition) path proven byte-identical.

## Verified
- FT-11 fast path byte-identical when reposition never touched (`effectiveCoordinate` = `repositioned ?? original`, traced end-to-end incl. submit wire shape)
- Landmine fix exact per spec §3.2: `applyRepositionUpdateIfNeeded` writes exactly three fields; sheet identity never touched; two tests pin the id-depends-only-on-coord precondition
- `resolveDisplayCoordinate`: clean three-way fallback (fraction → nearest-point → raw), no force-unwraps, 5 targeted tests incl. multi-vertex cumulative-length; precomputed once per pin (no per-frame projection)
- Downstream consumers all read updated placement post-reposition (no stale-half-state)
- Drive-mode-starts-mid-sheet: existing boundary force-dismiss covers it — no stranded affordance
- Counts exact 1407→1432; no supabase/Regulars/flags drift; no banned copy; all four judgment calls independently re-derived sound

## Findings
### 🟡 #1 — OD-1 reposition row can mount below the fold, no auto-scroll
`ReportSheet.swift:641-645`: S13c Fix #8's scroll guard (`showsConfirmStreetStep`) wasn't widened to `|| showsRepositionAffordance`. In the no-segment-resolved case (the case the spec says benefits MOST), the section renders only the Reposition row and never scrolls into view. Fix: widen the guard.
### 🟡 #2 — transient dual-active-mode window
`enterSpotPlacementMode()` sets spotPlacement synchronously; reposition state resets only in async `onDismiss` — both flags true for the dismiss-animation window ("mutually exclusive by construction" claim not literally true). Harmless today (tap precedence correct) but fix with a one-line synchronous reset in `enterSpotPlacementMode()`, mirroring `cancelSpotPlacementMode()`.
### 🟢 nits
Heading-toward enum preserved across cross-street reposition (matches spec; label updates — awareness only); `nonisolated` inconsistency beside promoted `nearestPointOnPolyline`; community-pin taps use the callout path not `handleMapTap` (traced, no swallow risk); inherited `bearing`-style race (pin added before tiles loaded stays raw until re-added — pre-existing class).

## Mac gate checklist
1. `xcodebuild test` — expect **1432/1432** (first compile of the branch)
2. Live smoke: Report → grid → **Reposition** row visible without scrolling (esp. the no-segment case post-fix) → map tap re-anchors (tentative marker + candidate list updates in place, sheet does NOT reset) → submit lands on tapped curb
3. Retro-snap: a known mid-block production pin now renders on its curb
4. Default-path parity glance (pill + long-press dialog entries)
5. Finding-#2 window: Reposition → immediately "Spot open" → no glitch
