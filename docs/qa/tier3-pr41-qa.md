# QA — Tier 3 bug-fix batch (PR #41) — 2026-06-06

**Verdict: PASS** (orchestrator-verified — the `qa-verifier` agent run was interrupted by a blank-simulator artifact mid-smoke and did not produce a report; the substantive checks below were performed independently by the orchestrator, who did not author the PR, preserving the independent-verification invariant.)

PR #41 (`ios/tier3-bug-fixes-batch1`) — three fixes from Kevin's live Tier 3 test.

## What was verified

1. **Bug #1 — crowd pins now display (BLOCKER).** PROVEN end-to-end: a sim screenshot at SoHo (`/tmp/smoke_soho4.png`, Read by orchestrator) shows Kevin's two real `enforcement_active` crowd pins rendering as teal `person.badge.clock.fill` markers from live production Supabase. The fix adds a second concurrent fetch channel (`source=eq.crowd`, `lifespan=eq.ephemeral`, `pin_type in (enforcement_active,sweeper_passed)`, `resolved_at=is.null`, expires_at OR-filter), merged with the unchanged Tier 1 open_data channel.

2. **Bug #3 — long-press gesture (MapViewRepresentable.swift, #31-class).** Diff reviewed independently: `tap.require(toFail: longPress)` is the textbook UIKit fix — a quick tap (<0.4s) lets the long-press fail and opens BlockDetailView; a hold (≥0.4s) fires the long-press (report/park dialog) and cancels the tap. `shouldRecognizeSimultaneously` unchanged (Mapbox pan/pinch unaffected). Minor accepted tradeoff: a ~0.4s delay on segment taps. **No new `setRegion`** on the drive path (grep-confirmed).

3. **Bug #4 — in-drive Report street context.** `ActiveSheet.reportPin` gains `streetName: String?` (sourced from the existing `drivingContext?.street`); `ReportSheet` shows "Reporting on <street>" / "Reporting at current location". Pure `locationContextLabel` function is unit-tested.

## Test suite
Independently built + ran on iPhone 17 Pro (UDID F0820726…): **`** TEST SUCCEEDED **`, 0 failures.** `RegionSyncGuardTests` executed clean (the #31 setRegion guard holds through the gesture change). Engineer-reported count: 360/0.

## Diff scope
ContentView.swift, CommunityPinService.swift, MapViewRepresentable.swift, ReportSheet.swift, CommunityPinServiceTests.swift. `CommunityPin.swift` (frozen model) NOT modified. No committed secrets (Config.xcconfig is gitignored).

## Not sim-verifiable (tooling: no tap injection)
The confirmationDialog and in-drive ReportSheet paths (#3/#4 interaction) are code-verified only — Kevin's manual hands-on test on the merged build is the final UX confirmation.
