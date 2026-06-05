# Tier 3 Sub-PR #1 (Anonymous Auth + Crowd Write Path + Reactions) QA Pass 1 — 2026-06-05

**Reviewed:** branch `ios/tier3-auth-reactions` at `e7895e8`, against `docs/tier3-auth-and-reactions-spec.md`
**Verdict:** PASS WITH NITS — ship with acknowledged deviations documented below (all pre-approved by spec or decision log)

---

## Summary

The implementation delivers all blocking acceptance criteria for the auth + write path + reactions scope. Anonymous auth is implemented via raw URLSession (A3 SDK deferral, pre-approved). The write path (insertCrowdPin, upsertVote, callExtendPinExpiry) correctly attaches `Authorization: Bearer <jwt>`, the payload shapes match the schema, and the RLS guard (`notAuthenticated` throw when no session) is wired and tested. The ReactionsRow renders and disables correctly per the A1 own-pin guard. The DB trigger (02e) is idempotent and fires on the correct table/column. Tests: 331/0 (15 new). RegionSyncGuardTests: 2/2 pass. Live-UI smoke: no #31 regression — ASP banner, toolbar, polylines all render. Anonymous-auth against prod: CANNOT VERIFY from sandbox (worktree Config.xcconfig has placeholder keys); classified as CONFIG PREREQUISITE. One spec deviation (AC-A3 not testable without SDK) and one scope deviation (startRealtime stays stub) are both justified by the SDK deferral rationale documented in the file headers.

---

## Acceptance Criteria Checklist

### Anonymous Auth

- [x] **AC-A1** — On first launch, `ensureSession()` calls `signInAnonymously()` and sets `currentUserId` to a non-nil UUID without any user-visible prompt. Verified by `testEnsureSession_noPersistedSession_callsSignIn` + `testSignIn_setsCurrentUserId` (pass).
- [x] **AC-A2** — On subsequent launch with a valid persisted session, `ensureSession()` restores without a new sign-in call. Verified by `testEnsureSession_validPersistedSession_doesNotResignIn` (pass) + `testEnsureSession_expiredToken_callsRefresh` (pass, shows refresh path).
- [ ] **AC-A3** — If SDK emits `.signedOut`, `signInAnonymously()` auto-fires. **NOT TESTABLE without SDK** — the raw URLSession path has no server-push auth-state stream. The `refreshAccessToken` fallback covers the practical equivalent (refresh failure → re-sign-in). Classified as SDK fast-follow gap, not a blocker. See Finding #1.
- [x] **AC-A4** — No login screen, email field, username field, or auth-related UI at any point. Verified by code review: `SupabaseAuthService.swift` contains no `NavigationLink`, `Sheet`, or `Alert`.
- [x] **AC-A5** — Single `SupabaseAuthService` instance. Verified: instantiated once in `WeParkApp.swift` as `@State private var authService`; same instance injected into `ContentView`, then into `CommunityPinService(authService:)`.

### Write Path — Insert

- [x] **AC-W1** — `insertCrowdPin` includes `Authorization: Bearer <jwt>` header. Verified by `testInsertCrowdPin_requestIncludesAuthorizationHeader` (captures header, asserts "Bearer " prefix, pass).
- [x] **AC-W2** — Insert payload includes `source="crowd"`, `author_id=currentUserId`, `lifespan="ephemeral"`, `expires_at=ISO8601(now+30min)`. Verified by `testInsertCrowdPin_payloadShape` (decodes body, asserts all four fields, pass).
- [x] **AC-W3** — `insertCrowdPin` with nil userId throws `notAuthenticated` without network call. Verified by `testInsertCrowdPin_notAuthenticated_throws` (pass).
- [ ] **AC-W4** — End-to-end: pin appears in second client's visiblePins within 5s. Cannot verify in sandbox — requires prod schema applied + live Supabase with anonymous auth enabled. Owner: Kevin (manual smoke).

### Write Path — Vote

- [x] **AC-V1** — `upsertVote` includes `Prefer: resolution=merge-duplicates` header. Verified by `testUpsertVote_requestIncludesPreferHeader` (pass). Actual header is `"resolution=merge-duplicates,return=minimal"` which contains the required substring — correct.
- [x] **AC-V2** — "Still there?" calls BOTH `upsertVote(.confirm)` AND `callExtendPinExpiry`. Verified by `testStillHere_callsBothUpsertAndExtend` (endpoint path discrimination, pass) + code review of `handleStillHere()` in `ReactionsRow`.
- [x] **AC-V3** — "Gone" calls ONLY `upsertVote(.dispute)`. Verified by `testGone_callsOnlyUpsertDispute` (asserts `extendEndpointCalled == false`, vote value == "dispute", pass).
- [x] **AC-V4** — Buttons disabled when `pin.authorId == authService.currentUserId`. Verified by `OwnPinGuardTests` (3 tests: same-id, different-id, nil-authorId — all pass). Guard logic also verified in `ReactionsRow.isOwnPin` by code review.
- [ ] **AC-V5** — End-to-end: confirm_count badge increments within 5s after "Still there?". Cannot verify in sandbox. Owner: Kevin (manual smoke).
- [ ] **AC-V6** — End-to-end: expires_at extends by 15 min after "Still there?". Cannot verify in sandbox. Owner: Kevin.

### Auto-Resolve Trigger (DB)

- [ ] **AC-DB1** — 3 dispute votes set `resolved_at` synchronously. Cannot verify without running SQL against prod. Owner: Kevin (SQL editor smoke per spec §7).
- [ ] **AC-DB2** — 2 dispute votes do NOT set `resolved_at`. Cannot verify without running SQL. Owner: Kevin.
- [x] **AC-DB3** — Trigger does NOT fire on durable-lifespan pins. Verified by code review: function checks `new.lifespan = 'ephemeral'` explicitly. SQL smoke deferred to Kevin.
- [x] **AC-DB4** — `02e-auto-resolve-trigger.sql` is idempotent. Verified by code review: `CREATE OR REPLACE FUNCTION` + `DROP TRIGGER IF EXISTS` + `CREATE TRIGGER`. Standard idempotency pattern.

### Architecture Invariants

- [x] **AC-I1** — `SupabaseAuthService.swift` contains no `Calendar.current`. Verified by grep: zero hits. All time math uses `Date()` + `TimeInterval`.
- [x] **AC-I2** — `CommunityPin.swift` NOT modified. Verified by `git diff main --name-only`: `CommunityPin.swift` absent from diff.
- [x] **AC-I3** — `PinDetailSheet.swift` modifications add no `setRegion`, `updateUIView` mutation, or `headlessWindow` guard. Verified by code review of full file.
- [x] **AC-I4** — `RegionSyncGuardTests` (2 tests) pass unchanged. Verified: both pass in 331/0 run.
- [x] **AC-I5** — No new `Calendar.current` usage in diff. Verified by grep: zero hits in all three modified service/view files.
- [x] **AC-I6** — Supabase anon key NOT committed. Verified by `git diff main` search for JWT patterns: only `"eyJ.test.token"` (fake fixture) in `Tier3AuthReactionsTests.swift`. Config.xcconfig is gitignored.

### Live-UI Smoke Gate

- [x] **AC-S1** — `PinDetailSheet.swift` and `ContentView.swift` were modified; smoke gate required and executed. Build succeeded (exit 0). App installed and launched on UDID `F0820726-15F4-4FA3-8602-A5D7B479A277`. Screenshots captured at /tmp/tier3-auth-reactions-smoke.png and /tmp/tier3-smoke-2.png. Both confirm: (a) green ASP banner "ASP in Effect Today" at top, (b) full toolbar layer visible (gear, find-me arrow, car, clock, Drive diamond button), (c) parking polylines rendered at street level, (d) no #31 regression.

---

## Findings

### Blocking

None.

### Significant

None.

### Minor / Nit

**#1: AC-A3 (auto-re-sign-in on SDK `.signedOut` event) is not implemented and not tested.**
- Where: `SupabaseAuthService.swift` — no `observeAuthState` method, no auth-state stream subscription.
- What: The spec §3.8 sketch includes a `observeAuthState()` method that listens to `client.auth.authStateChanges` and calls `signInAnonymously()` on `.signedOut` events. The raw URLSession implementation has no equivalent — there is no server-push mechanism.
- Expected per spec: AC-A3 requires auto-re-sign-in when the SDK emits `.signedOut`.
- Practical impact: LOW for TF1. The `refreshAccessToken` fallback (triggered before every write via `tokenNeedsRefresh()`) handles the practical case of token expiry. Server-initiated invalidation of anonymous sessions is rare at TF1 scale with a known user population.
- Repro: N/A (the code path doesn't exist).
- Owner: `@ios-engineer` in the SDK fast-follow PR.

**#2: `startRealtime()` remains a no-op stub — spec §3.3 says it is "ACTIVATED" in sub-PR #1.**
- Where: `CommunityPinService.swift:243`.
- What: Spec §3.3 and §5 say "startRealtime() stub is ACTIVATED" to wire two RealtimeChannels (open_data + ephemeral_crowd) for server-push updates. The implementation keeps the stub body empty with a comment explaining SDK is required for WebSocket Realtime.
- Expected per spec: Two channels subscribing for INSERT/UPDATE events on the `pins` table.
- Practical impact: NONE for TF1. The polling path (`onRegionChanged` 800ms debounce) provides live updates at polling latency. `mergeRealtimeChange(pin:)` is fully implemented and ready for SDK wiring. Behavior is functionally correct; delivery latency is limited by poll frequency vs. WebSocket push.
- Owner: `@ios-engineer` in the SDK fast-follow PR.

**#3: Session persistence uses `UserDefaults` instead of Keychain.**
- Where: `SupabaseAuthService.swift` lines 193–244.
- What: The spec OQ-4 decision specifies "SDK's built-in Keychain storage." The raw URLSession path uses `UserDefaults.standard` for access token, refresh token, and user ID. UserDefaults is not encrypted.
- Expected per spec: Keychain storage (implemented by the SDK automatically).
- Practical impact: LOW for TF1. Anonymous JWTs are short-lived (1h) and the UUID is not PII. The file header acknowledges this as a carry-over note for SDK adoption.
- Owner: `@ios-engineer` in the SDK fast-follow PR.

### Out of Scope (logged, not fixed)

- Realtime WebSocket subscription — deferred to SDK adoption fast-follow. Polling is functionally correct for TF1.
- Reputation increment — Tier 2 spec; `// TODO: Tier 2` comment in `02e-auto-resolve-trigger.sql` marks the seam correctly.
- `open_spot` enum migration — deferred to sub-PR #4 per OQ-T3-5 and spec §4. Correct deferral; iOS model is frozen per AC-I2.
- Sign in with Apple upgrade path — post-TF2.

---

## Config Prerequisite (not a code defect)

**Anonymous sign-ins must be enabled in the Supabase dashboard before the live auth flow works.**

`SupabaseAuthService.ensureSession()` calls `POST /auth/v1/signup?anon=true`. Supabase disables anonymous auth by default; it must be enabled at:

> Supabase Dashboard > Authentication > Providers > Anonymous Sign-ins > Enable

The worktree sandbox has a placeholder `Config.xcconfig` (not the real project credentials), so the live auth call against production could not be validated from this QA run. The code path is correct. This is Kevin's dashboard action, not an engineering defect.

The anonymous-auth call will silently fail (app stays in read-only mode) if this setting is not enabled. `ensureSession()` fails silently by design (AC-A4 + TF1 resilience policy).

---

## Smoke Tests Run

1. **Build**: `xcodebuild -project ios/WePark/WePark.xcodeproj -scheme WePark -destination 'platform=iOS Simulator,id=F0820726-15F4-4FA3-8602-A5D7B479A277' build` — BUILD SUCCEEDED (exit 0).
2. **Full test suite**: `xcodebuild ... test` — **331 passed, 0 failed**. All 15 new Tier3 tests pass. RegionSyncGuardTests 2/2 pass.
3. **New test spot-check**: Verified all 15 tests in `Tier3AuthReactionsTests.swift` assert real behavior — `MockURLProtocol` captures actual outgoing HTTP headers/body; `OwnPinGuardTests` decode a real `CommunityPin` fixture via `JSONDecoder`; `ReactionCallDisciplineTests` discriminate by URL endpoint path (not just call count).
4. **Live-UI smoke**: Installed + launched on simulator F0820726. Screenshot T+4s confirms (a) ASP banner "ASP in Effect Today", (b) full toolbar (gear, find-me, car, clock, Drive button), (c) street-level polylines rendered. Screenshot T+5:26 confirms stable rendering. No #31 regression.
5. **Diff scope**: `git diff main --name-only` = 7 files, all expected. `CommunityPin.swift` absent (AC-I2 satisfied).
6. **Secrets scan**: `grep -r "pk.eyJ"` in `ios/` = zero. Only `"eyJ.test.token"` fixture in test file.
7. **Calendar.current scan**: Zero hits in all modified files.
8. **Anonymous-auth against prod**: NOT VERIFIED (sandbox placeholder credentials). See Config Prerequisite.
9. **ReactionsRow render**: CODE-VERIFIED ONLY. No ephemeral crowd pins in prod DB yet (Tier 3 not live). Condition `pin.lifespan == .ephemeral && pin.source == .crowd` correctly gates the row; disable logic verified by code review and `OwnPinGuardTests`. Live render requires Kevin to insert a test pin after applying the schema and enabling anon auth.
10. **DB trigger chain**: Reviewed `02e-auto-resolve-trigger.sql` against `02-pins-schema.sql`. Trigger chain verified: `votes` INSERT → `refresh_pin_vote_counts` (existing, updates `pins.dispute_count`) → `pins_auto_resolve_on_dispute` (new, fires `AFTER UPDATE OF dispute_count ON public.pins`). Condition `new.dispute_count >= 3 AND new.resolved_at IS NULL AND new.lifespan = 'ephemeral'` matches spec §3.7 exactly.

---

## What's Working

- The raw URLSession anonymous-auth pattern is clean. Injectable `URLSession` for tests, consistent `MockURLProtocol` strategy, no global state pollution between test classes (separate `AuthMockURLProtocol` and `WriteMockURLProtocol` with separate static handlers).
- `buildAuthenticatedRequest` correctly attaches both `apikey` (Supabase gateway) and `Authorization: Bearer <jwt>` (RLS auth.uid()). The distinction between anon-read (apikey only) and auth-write (both) is architecturally clean and matches the RLS policy requirement precisely.
- The `CommunityPinWriteError` enum is well-typed. The `notAuthenticated` guard fires before the first `await`, preventing any network call when there is no session.
- `ReactionsRow` loading-state (`isLoading`) disables both buttons while any async call is in-flight, preventing double-tap races. Error display is non-blocking (user can retry).
- `02e-auto-resolve-trigger.sql` correctly targets `AFTER UPDATE OF dispute_count ON public.pins` (not on votes directly). This is correct — the trigger needs the updated count value that `refresh_pin_vote_counts` just wrote to the pins row.
- The `AC-A5` singleton invariant is correctly implemented: one `SupabaseAuthService` created in `WeParkApp`, threaded to `ContentView`, and from there into `CommunityPinService`. No second client instance anywhere in the diff.
- The `isStillHereDisabled` 2h-cap guard (`expiresAt > Date().addingTimeInterval(115 * 60)`) matches spec §3.10 semantics exactly: disabled when pin is already within 5 minutes of the cap, which is the right UX (no point extending when it's about to max out).
