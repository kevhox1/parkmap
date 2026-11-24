# PR #178 (perf/map-lag) QA — 2026-11-24

**Reviewed:** `perf/map-lag` @ def3a33e vs `main`. **Verdict: MERGE-WITH-FOLLOWUPS** (no correctness defects found; perf gain not independently measured).

## Correctness review of the cache (primary risk)
`engine.currentState(for:at:)` and `engine.isFree(segment:from:until:ignoringMeteredPayment:)` are pure in (segment, now, target, metered flag). Verified by reading `ParkingRulesEngine`:
- ASP suspension: `ASPSuspensionService` is immutable after init (bundled asp-2026.json), so it is not a hidden input.
- Goal / target / metered flag: all in the key (`.parkUntil(target:ignoringMeteredPayment:)`); goal switches change target or flag and drop the cache. Separate cache instances for 5-state vs Park Until.
- `now` granularity: key is EXACT `now` (no rounding), so a rule boundary (e.g. 7 PM) cannot be crossed with a stale answer: any new `now` (60 s timer, `.nowET` callers) drops the whole cache. Cost: hits only occur for rebuilds that reuse `lastEvaluatedAt` (region/segments-change paths), which is the intended case. Callers passing `.nowET` fresh never hit (harmless).
- Segment identity: tiles are bundled static data; the only writer of `TileLoader.segments` is `rebuildSegments`, so same id => same rules within a session. No remote tile refresh exists. Same id in two adjacent tiles has identical content.
- Selected segment, community pins, dark/light mode, curb-placement mode: none feed classification (selected segment is skipped before lookup; pins/appearance are render-side).
- `canSkipRebuild`: cache mutations only in `insertIntoCache`/`evictIfNeeded`, both bump `cacheVersion`; `touchInCache` does not change contents. Key list compared in order. First call never skips. Rebuild triggers key off `segments.count` (`onChange`), not array republish, so skipping an identical republish removes no rebuild trigger.
- Cache valve: >50k entries clears. Fine.

## Simulator (iPhone 17, Flatiron 40.7410,-73.9897, five flags true locally, fresh install each build)
Screenshots in `docs/qa/assets/pr178/` (`main-*` vs `pr-*`):
- Browse Overnight (default), A Few Hours, Park & Forget: curb colors identical main vs PR (compared 03 and 04 pairs visually; 01/02 same camera/colors). Goal switching produces visibly different, correct-looking colors on both.
- Drive mode (Overnight, "Good through Thu"): overlays/colors identical (pr-05 is dimmed by a first-run "Keep WePark in Front" modal that main skipped, because PR install was a fresh uninstall; underlying lines match main-05).
- Pan (two swipes) on PR: overlays render for newly visible area, nothing blank (pr-06).
- Not done: no `--speed` route driving, no pinch (AXe), no wall-clock rule-boundary crossing in the sim; boundary safety is by code reasoning only. Pixel-diff not done (no PIL); comparison is by eye.
- Perf claims (45-64 -> 4.7-17 ms, 7->4 calls) NOT independently measured. Tests not run (CI green).

## Follow-ups (non-blocking)
- 🟢 `.nowET` call sites never hit the cache; if the speedup claim relies on them, confirm with Instruments on device in drive mode.
- 🟢 `onChange(of: segments.count)` is pre-existing weak: tile window shifts with equal total count would not rebuild; unrelated to this PR.
- 🟡 Recommend an on-device pinch-zoom check in TestFlight drive mode, since sim cannot reproduce the owner's lag.
