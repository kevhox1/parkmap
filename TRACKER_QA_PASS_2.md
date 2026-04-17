# Tracker QA Pass 2 — Post PR #5 + #6 Audit

- **Date:** 2026-04-17
- **Branch / commit audited:** `main` at `1f8b005de646fef809f0ccb320b1fbfadd3ecd40`
- **Scope:** Code-level QA against current `main`. No live browser smoke run; static review of `index.html`, `sw.js`, `tracker-config.js`, plus spec cross-check.
- **Baseline:** `TRACKER_QA_VERIFY.md` (dated 2026-04-07, against branch `tracker-impl-v2` @ `a7c13e1`). That doc is now stale — PR #6 explicitly targets the 6 issues it flagged.

## Method note

- Line numbers below are from `index.html` on `main` at `1f8b005`. File is 4948 lines.
- Verified each original finding against the current implementation. Flagged new issues scanned from a diff-minded read of the provider plumbing and SW.
- Did not spin up a browser — live regression tests (Supabase fallback behavior, mobile bottom-sheet rendering, marker taps) are called out as `NEEDS LIVE VERIFY` in the follow-ups section.

---

## Original-six verdict table

| # | Issue | Status | Evidence |
|---|---|---|---|
| 1 | Park My Car CTA mismatch (button labeled "Park My Car Here" but calling `openParkModal()`) | ✅ Resolved | `index.html:841` — `onclick="parkCarHere()"`. `parkCarHere()` at `index.html:4038` routes to `openParkModalForPin(center.lat, center.lng)`. |
| 2 | Pin mode snaps to nearest vertex, not projected point on polyline | ✅ Resolved | `findClosestSegment()` at `index.html:4043` now calls `getClosestPointOnSegmentGeometry()` (at `index.html:3522`) which does true point-to-segment projection with clamped `t` per polyline segment (`index.html:3551-3569`). |
| 3 | Future ASP suspensions ignored by Smart Score / Smart Move timing | ✅ Resolved for ASP path | `computeHoursUntilASP()` at `index.html:2905` now walks `offset < 14` future days and calls `isASPSuspended(toETDateStr(checkDate))` per day (`index.html:2913`), skipping suspended days. `computeNextRestrictionHours()` at `index.html:4258` consumes that via `computeHoursUntilASP()` at `4299`. ⚠️ Note scope: the fix applies to ASP categories only. `computeHoursUntilActive()` (used by `NO_PARKING` / `TRUCK_LOADING` at `index.html:4285`) was not in scope for the original finding and is unverified here. |
| 4 | Smart Move had two engines (panel used `computeSmartMove`; blue CTA used `generateSmartMoveRecommendation` with its own ranking) | ✅ Resolved | `generateSmartMoveRecommendation()` at `index.html:4915` now simply calls `computeSmartMove()` and reads `smartMoveRecommendation` (populated inside `computeSmartMove()` at `index.html:4559`). Single ranking source of truth. |
| 5 | Narrow-phone bottom-sheet overlap (control panel + Top Blocks both rendered as bottom sheets below 480/399px) | ✅ Resolved (structurally) | `isCompactBottomSheetLayout()` at `index.html:3012` (breakpoint 480px), `syncResponsivePanels()` at `index.html:3026` hides `topBlocksPanel` unless the control panel is collapsed on compact layouts (`index.html:3042-3043`). Entering smart-score mode auto-collapses control panel on compact (`index.html:2603-2605`). Wired to `window.resize` at `index.html:4866`. **NEEDS LIVE VERIFY:** 399px range where `.control-panel` also becomes a bottom sheet (`index.html:486-491`) — the JS-level coordination looks correct, but physical overlap vs stacking should be eyeballed on a real 360px viewport. |
| 6 | `block_cleaned` ages like a generic 10-minute report | ✅ Resolved | `trackerAgeClass()` at `index.html:1364` now branches on `report.type === 'block_cleaned'` and pegs freshness to `expires_at` / `asp_window_end_at`. `fresh` while more than 10 min remain in the ASP window, `aging` during the final 10 min, `stale` only after window end. |

**Summary:** 6 of 6 resolved structurally. Items 3 and 5 have narrow caveats worth a second look.

Item 7 in the stale doc (tile cache concern) was already partial; SW cache version now reads `wepark-v6` (`sw.js:1`) and Supabase live traffic is correctly bypassed via `isSupabaseLiveRequest()` (`sw.js:52-59`, used at `sw.js:67-70`). Cache-first for `tile_*.json` is unchanged (`sw.js:105-125`) — same structural caveat as before, tile freshness still depends on version discipline.

---

## New findings (introduced by PR #5 / #6 or noticed during the audit)

### NF-1 (Low) — Legacy config shim `WEPARK_SUPABASE_CONFIG` is a silent alternate provider switch
`getTrackerRuntimeConfig()` at `index.html:1455-1469` accepts a `window.WEPARK_SUPABASE_CONFIG` fallback (`legacy.url` / `legacy.anonKey`). If someone accidentally leaves that global set in an old browser tab or sideloaded script, Supabase mode activates even when `tracker-config.js` says `provider: 'mock'` (because `provider = cfg.provider || ((legacy.url && legacy.anonKey) ? 'supabase' : ...)` — but `cfg.provider` is always present since `tracker-config.js` always sets it, so in practice the legacy keys only matter for URL/key sourcing). Not a security issue, but it's a hidden coupling with no tests. Consider removing once no environment still uses the old global.

### NF-2 (Low) — Mock-vs-Supabase `getBlockFaceDetail` shape divergence
Mock provider returns `{ reports, events }` (no `blockFace`, no `comments`) — `index.html:1635-1646`. Supabase provider routes through `normalizeTrackerDetail()` which returns `{ blockFace, reports, events, comments }` — `index.html:1510-1527`. Downstream, `showBlockInfo` assigns into `trackerDetailCache` at `index.html:4117` and later in the render path reads `trackerDetail.reports` / `.events`, which are the common fields. Works today, but:
- Any UI surface that tries to read `trackerDetailCache.blockFace` or `.comments` will get `undefined` in mock mode and normalized objects in Supabase mode. That's a live foot-gun when the Supabase backend is first wired.
- Fix forward: run mock through `normalizeTrackerDetail()` too, or document the contract in one place.

### NF-3 (Low) — Supabase provider has no `seedReports` method
`maybeSeedTrackerDemoReports()` at `index.html:2011` is correctly gated on `trackerProvider.kind !== 'mock'` before invoking `seedReports()`, so Supabase mode doesn't crash. But `seedReports` is part of the mock provider's *de facto* interface (`index.html:1794-1810`) and not the Supabase one — so the method is implicitly "mock only." Worth a comment on the provider contract, otherwise someone will try to seed live data with it later.

### NF-4 (Low) — Supabase provider cannot retract seed reports
`retractReport` in the mock provider enforces `report.reporter_user_id !== session.id` (`index.html:1780`). Seed reports use `reporter_user_id: 'seed'` (`index.html:2034`, `2058`, `2084`). In mock mode the logged-in session ID is `'local-demo-user'` (`index.html:1621`), so users can never retract demo reports — by design, fine. Just flagging: this also means the mock's retract-own flow is only exercised against user-created reports, not seed, so the QA surface for retract UX is a little thin.

### NF-5 (Low) — `console.log('ParkMap ready...')` + `console.log('Tile index loaded...')` ship to prod
`index.html:1168`, `1250`, `4855`, `4944` plus a handful of `console.warn` / `console.error` calls. All are benign and actually useful for debugging on the live GitHub Pages deploy. Noting for completeness — not a blocker.

### NF-6 (Informational) — `enableDemoAuth` alias is dead code in Supabase path
Supabase provider exposes `enableDemoAuth` as an alias of `signInForWrites` (`index.html:1920-1922`). The only caller is `trackerPromptAuth()` / `trackerUseDemoAuth()` (both ending up calling `signInForWrites` first, then `enableDemoAuth` as fallback) at `index.html:2280-2284`. Not wrong, just two names for the same thing in the Supabase path. Low severity, but when you rename for Supabase clarity, drop the alias.

### NF-7 (Low) — `computeHoursUntilActive` (non-ASP path) not verified for future suspensions
Non-ASP restrictions (`NO_PARKING`, `TRUCK_LOADING`, `METERED`) go through `computeHoursUntilActive()`, which isn't re-examined in PR #6. Those categories don't care about ASP suspensions by design, so this is probably fine — but if a "no parking" rule coincidentally falls on a suspension date (e.g., a special-event closure), the suspension wouldn't hide it. Almost certainly correct behavior; flagging for awareness.

### NF-8 (Low) — SW `STATIC_ASSETS` references `tracker-config.js` but not the Supabase ESM CDN import
`sw.js:8` caches `tracker-config.js` as a static asset. The Supabase client is loaded via `await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm')` at `index.html:1819`. That dynamic import is not in `STATIC_ASSETS`, but the SW fetch handler falls through to network-first for non-Supabase third-party URLs (`sw.js:128-138`). First-load-offline won't work for Supabase, which is acceptable: you can't reach Supabase offline anyway. Worth documenting this as "Supabase requires network on first use" since it's non-obvious.

### NF-9 (Low) — `allowMockFallback` is cosmetic in the current config
`tracker-config.js` sets `allowMockFallback: true` by default. The only consumer is `initTracker()` at `index.html:1996`, which re-throws if fallback is disabled. Since the default config in both `tracker-config.js` and `DEFAULT_TRACKER_CONFIG` at `index.html:1041-1050` already uses `provider: 'mock'`, the fallback path is effectively unreachable until someone flips `provider: 'supabase'` with bad creds. That's the intended shape — flagging so you know the fallback has literally never executed in production.

### NF-10 (Informational) — Graceful degradation when `tracker-config.js` is absent
The config is loaded synchronously via `<script src="tracker-config.js">` at `index.html:14`. If the file ever 404s, `window.WEPARK_TRACKER_CONFIG` is undefined, and `getTrackerRuntimeConfig()` falls back to `DEFAULT_TRACKER_CONFIG` (mock). That's correct behavior. The SW also caches the file, so an accidental delete from the repo wouldn't break existing installs immediately.

---

## Recommended follow-ups, ordered by severity

### Must do before wiring real Supabase credentials
1. **Normalize mock detail shape.** Run mock `getBlockFaceDetail` output through `normalizeTrackerDetail()` so `trackerDetailCache` has the same fields regardless of provider (NF-2). Prevents "works in mock, breaks in Supabase" UI bugs at cutover.
2. **Live smoke on a 360px-wide viewport.** Verify the Top Blocks sheet + control panel actually coexist correctly on phones with `isCompactBottomSheetLayout()` gating (NEEDS LIVE VERIFY on Issue #5). Code looks correct; want visual confirmation.
3. **Live smoke: Supabase bad-creds → mock fallback.** Temporarily set `provider: 'supabase'` with dummy creds and confirm `initTracker()` falls back to mock and the UI badge reads "Local demo" (currently untested path per NF-9).
4. **Live smoke: auth-required flow on Supabase.** When a write hits `auth_required` (PGRST301 / missing JWT), confirm the auth gate re-opens per the code path at `index.html:1857-1860`. Spec expects graceful re-open, not hard error.

### Nice to do before Supabase
5. Add a one-line comment on `seedReports` that it's mock-only (NF-3).
6. Drop the `enableDemoAuth` alias in Supabase provider, or drop `signInForWrites` in mock to unify the name (NF-6).
7. Consider removing the `WEPARK_SUPABASE_CONFIG` legacy shim if no environment still depends on it (NF-1).

### Can wait
8. `computeHoursUntilActive` future-suspension audit (NF-7) — only matters if non-ASP rules ever intersect with suspension dates, which is unlikely by design.
9. Document in `tracker-config.js` that Supabase needs network for first use (NF-8).

---

## Clean to proceed?

**Qualified yes.** The six issues from `TRACKER_QA_VERIFY.md` are genuinely resolved in code. Provider abstraction is clean, mock and Supabase both plug into the same `trackerProvider` interface, SW bypass is correct, cache is v6, auth-gate rendering is provider-aware.

Two things I would not skip before pointing the app at a real Supabase project:

1. **Mock-vs-Supabase detail shape normalization (NF-2).** This is the most likely cutover bug. Ten minutes of work, saves an afternoon of "why does the block sheet render blank on Supabase."
2. **Live smoke of the Supabase-bad-creds → mock-fallback path (NF-9).** The code looks right, but that path has never executed in anger. Test it with dummy creds before shipping with real ones so you know the graceful-degrade story works end-to-end.

Everything else is polish. Tracker is production-ready-enough for the real Supabase wire-up as soon as those two boxes are ticked.

---

## Items that surprised me

- PR #6 actually closed all six original findings cleanly. The stale doc overstates the risk — worth flagging so Kevin doesn't keep treating it as the current state.
- `generateSmartMoveRecommendation` went from having its own proximity-weighted scoring engine to literally being a thin alert wrapper around `computeSmartMove()`. That's the right simplification but it's more aggressive than I expected — the blue CTA is now basically a popup of the always-visible panel. Worth a UX gut-check on whether both surfaces are still needed.
- The mock provider is the one with merging logic (duplicate same-type+same-direction reports become confirmations) per the spec section 5.5. The Supabase provider just calls RPCs and trusts the DB to merge. That's correct, but it means the merge semantics live in two places (SQL for Supabase, JS for mock) and could drift — worth a note in `SUPABASE_MVP_SCHEMA.md` that the mock is the reference impl.
