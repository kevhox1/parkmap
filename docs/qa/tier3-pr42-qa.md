# QA — Tier 3 pin refresh + instant feedback (PR #42) — 2026-06-06

**Verdict: PASS** (orchestrator-verified — independent of the PR author; the live-render proof below was the critical check the engineer could not perform from a worktree lacking prod creds).

PR #42 (`ios/tier3-pin-refresh-and-feedback`) — fixes for Kevin's live test: reported pins were slow/missing because there was no instant feedback and no auto-refresh.

## Fixes
1. **Instant feedback** — `insertCrowdPin` now uses `Prefer: return=representation`, decodes the row, and appends via `mergeRealtimeChange(pin:)` so a reported pin shows immediately (test: `testInsertCrowdPin_successWithRepresentation_appendsPin`).
2. **Periodic refresh** — a repeating re-fetch of the current visible region (interim stand-in for websocket Realtime, which is the SDK follow-up) so pins from self + others appear and expired ones drop without manual panning.
3. **Marker safety net** — `PinMarkerAnnotation.markerImage(for:)` falls back to a colored filled circle if an SF Symbol fails to resolve, so a pin never silently disappears.

## Tests
Engineer-reported **373/0**, RegionSyncGuardTests pass. (Display-layer changes — CommunityPinService + PinMarkerAnnotation — lower #31 risk than PR #41's gesture change.)

## Live render proof (orchestrator, with real prod creds)
Built the PR branch with main's real `Config.xcconfig`, launched at SoHo. First pass showed no markers — correctly, because Kevin's earlier test pins were ephemeral (30 min) and had EXPIRED (correct client-side-expiry behavior). Inserted two FRESH crowd pins via the live anon-auth path (enforcement_active @ 40.7232/-73.9933, sweeper_passed @ 40.7228/-73.9945, both 201 OK). Screenshot `/tmp/pr42-fresh-markers.png` (Read by orchestrator) ~35s later, WITHOUT panning, shows BOTH a teal `person.badge.clock.fill` enforcement marker AND a cyan `truck.box.fill` sweeper marker rendered from the live DB. This proves: (a) sweeper now renders — the missing-marker symptom is resolved, (b) periodic refresh works — pins appeared without a region-change, (c) the prior "expired" behavior is correct.

## Note
Two test pins inserted with a 2099 expiry for the smoke will NOT auto-expire — orchestrator to delete them before wrap so prod stays clean.
