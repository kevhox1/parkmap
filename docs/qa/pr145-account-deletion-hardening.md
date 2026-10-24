# PR #145 QA Pass 1 - Account-deletion hardening (fixes PR #144 QA Y1/Y2/Y3)

**Reviewed:** branch `fix/account-deletion-hardening` at `62aee0ad`, against `docs/qa/pr144-account-deletion-and-suggest-neighborhood.md`, `supabase/10-account-deletion.sql`, `12-storage-delete-own.sql`, `docs/supabase-ceremony-10-11.md`, `supabase/02f-block-scoped-restrictions.sql` section 8.
**Verdict:** MERGE (flags stay `false`). No blocking defect. One 🟡 (not-found recognition can trap a retrying user) should be fixed or live-verified before `accountDeletionEnabled` is flipped, not before merge.

## Hard limits of this review (read first)

- **Live Supabase behaviour was not exercised.** The Storage `info` route and its not-found body, GoTrue error shapes, and a real Keychain delete failure are judged from knowledge of storage-api / GoTrue, not measured.
- **No simulator run.** No mount-chain file is touched (`ContentView`, `MapViewRepresentable`, `Views/DriveMode*`, safeAreaInset code all absent from the diff), so the live-UI screenshot rule does not apply. `CrewFeedSection` is live UI but not a mount-chain file; its change is state-keying, covered by value-type tests; I did not screenshot it.
- **CI claim verified independently.** `gh run view 40039583827`: conclusion `success`, `headSha` = `62aee0ad` (== branch HEAD), job "Build and XCTest (Xcode 26)" green, log shows `** TEST BUILD SUCCEEDED **`, `** TEST EXECUTE SUCCEEDED **`, `Executed 2004 tests, with 0 failures (0 unexpected)`, zero "Failing tests" lines. The four new suites (`AccountDeletionHardeningTests`, `SupabaseAuthServiceAccountDeletionTests`, `CrewFeedProfileStateTests`, `AccountDeletionRegularsResetTests`) each report `passed`. Compile and unit-test results are therefore established; this review is on logic and live-app regression risk.
- **supabase-swift v2.55.0 source WAS read** (fetched from the tag; the repo's `Package.resolved` pins 2.55.0 at `a71f55a8`). Citations below.

## Summary

The three fixes are sound and the flag-off live app is behaviourally unchanged in every path I traced. The riskiest piece, the shared `.signedOut` routine in `SupabaseAuthService`, is identical to the old handler whenever the SDK has already removed the session (which is every real-world `.signedOut`), and strictly better in the one race the old handler had. The weakest point is the strict not-found recognition on the Y1 probe: it is fail-safe, but if the live body differs it removes the only escape for a user whose first attempt removed photos and failed at the RPC.

## Flag-off / never-deleted regression analysis (the key risk)

`revokedUserIds` is written in exactly one place (`endSessionAfterAccountDeletion`), whose only caller is `AccountDeletionService.deleteAccount()` after the RPC succeeded. With the flag off nothing can call it, so the set is empty for the life of every process and every added `!revokedUserIds.contains(...)` is a no-op. A live user cannot be marked revoked (see "Can a LIVE user be marked revoked" below).

| Scenario | Old behaviour | New behaviour | Same? |
|---|---|---|---|
| First launch, no session | `ensureSession()`: `authClient.session` throws `sessionMissing` (SDK emits no event for a never-had-a-session) -> `signInAnonymously()` single-flight, one mint | Identical code path; only addition is an always-true revoked guard | Yes |
| Token refresh | `.tokenRefreshed` -> `applySession` | same, plus empty-set guard | Yes |
| App foreground | no change in this PR | no change | Yes |
| Offline launch | `session` fails/throws, mint fails silently, retried by next `validAccessToken()` | same | Yes |
| Session expires, refresh fails with `session_not_found`/`session_expired`/`refresh_token_*` | SDK `APIClient.handleError` does `sessionManager.remove()` THEN `emit(.signedOut)` (v2.55.0 `APIClient.swift:117-123`); handler: `clearSession()` + `signInAnonymously()` | handler: `adoptOrMintReplacement()`: `currentSession` is nil (SDK just removed it) -> `clearSession()` + `signInAnonymously()` | Yes, byte-equivalent in effect |
| `.signedOut` while a replacement session is already stored (race with `ensureSession`/lazy mint) | cleared cache, then `signInAnonymously()`; if the earlier mint had already finished (`pendingSignIn == nil`) this minted a SECOND anonymous user | adopts the stored session, mints nothing | Differs, strictly better (removes a latent double-mint) |
| `.signedOut` and the SDK's storage delete failed (Keychain error is logged and swallowed by `SessionStorage.delete`) | cleared cache, minted a new user that overwrote the stale one | `currentSession` still returns the stale session, so it is ADOPTED; no mint | Differs; see 🟢 #G2 (self-heals on next write, no loop) |

**Can a LIVE user be marked revoked / have their token refused?** No. Insert site is the single call after a 2xx from `delete_my_account` (or the 401+GoTrue-confirmation branch, #G3). The id inserted is the snapshot's own user id. A new anonymous identity gets a new UUID, so the marker can never match a later live user. It is never cleared (in-memory, process-lifetime), which is correct: user ids are unique and the marker only matters if the dead session is still on disk, and once the replacement is stored it overwrites the dead one.

**Crew feed, normal returning user.** `authService.currentUserId` is set at launch before the sheet opens, so the first `.task(id: CrewFeedLoadKey)` run is the same single profile + leaderboard load as before; the key only differs from the old `selectedZoneId` key if the user id changes. Token refresh calls `applySession` with the same user id; `.task(id:)` and `.onChange(of:)` both compare by `Equatable`, so no re-run. Observed differences, all only on an actual identity change: the nil -> id transition (first mint while the feed is already open) now reloads once (previously the load was never retried until a zone switch, which the old doc comment said it intended) and clears `leaderboardEntries` once. A fresh anonymous identity after token loss now drops the dead identity's profile card instead of showing it forever. The `loadProfileIfNeeded` fetch is guarded against the identity changing mid-flight. A pre-existing quirk is unchanged: a zone switch cancelling the in-flight profile fetch records `nil` for that user (old code did the same).

**RegularsService.** One `addObserver` in `init` for a notification that is never posted flag-off; `deinit` removes it; reset is main-queue, `[weak self]`. Inert.

**SupabaseClients.** `sessionWipe` is a stored closure and a `static let` key; `makeAuthService()` passes it. Construction is unchanged otherwise. **Constants.swift:** doc comment only.

## Acceptance checklist

**Y1 - empty-listing guard**
- [x] Rows query correct and scoped: `GET /rest/v1/pin_evidence?select=storage_path&uploaded_by=eq.<lowercase uid>&order=id.asc&limit=1000&offset=N`, user JWT + apikey. RLS `pin_evidence_select_own` (`auth.uid() = uploaded_by`) enforces own-rows server-side as well; the filter is belt and braces. Column name `storage_path` matches 02f:479. Verified by reading plus `testY1_rowsRequest_isScopedToCaller_andAuthenticated`.
- [x] Rows-query failure aborts before the RPC (non-2xx or undecodable -> `photoCleanupFailed`; `testY1_rowsRequestFailure_abortsBeforeRpc`).
- [~] Pagination: pages by 1000 and stops on a short page, 50-page cap. Correct against the Supabase default `max-rows = 1000`; see 🟢 #G1 for the case where the project's max-rows is lower.
- [x] Mixed listing probes only the missing rows; duplicates probed once (`seen` set); consistent listing makes zero probes (so ordinary first-time deletion makes no extra request at all).
- [x] Path equality is exact: `PinEvidenceUploader` writes `storage_path = objectPath = <uid lowercased>/<group lowercased>/<UUID>.jpg` (`PinEvidenceUploader.swift:203-209`), and the listing rebuilds `<prefix lowercased>/<folder>/<file>`; no case or normalisation gap.
- [x] Retry after a run that removed files but failed at the RPC proceeds when probes say not-found (`testPartialRemovalThenRetry_secondRunSucceeds`, `testY1_emptyListing_rowExists_probeNotFound_proceeds`). Not the naive "rows exist but listing empty -> abort" rule.
- [x] Abort only if the object still exists (2xx) or the probe is inconclusive (fail safe).
- [~] Route and body: see 🟡 #S1. `GET /storage/v1/object/info/authenticated/{bucket}/{path}` is a real storage-api route (user JWT, private buckets). A missing object is reported as `{"statusCode":"404","error":"not_found","message":"Object not found"}`, historically sometimes with HTTP 400 (hence the builder's 400-or-404). I am fairly (not fully) confident in that shape. NOT verified live.

**Y2 - identity handoff**
- [x] Marks the deleted user revoked first; token never served for it (`validAccessToken`, `currentSessionSnapshot`, `ensureSession`, and the `.signedIn/.tokenRefreshed` handler all check).
- [x] `signOut(.local)` ordering claim CONFIRMED in v2.55.0 `AuthClient.signOut` (line 1092+): if a session is stored, it does `await sessionManager.remove()` then `eventEmitter.emit(.signedOut, session: nil)` BEFORE the `/logout` request; 401/403/404 from `/logout` are swallowed, other errors propagate (caught by the `try?`). If NO session is stored the method returns early with no event and no request (the builder covers this: `testEndSession_withNoStoredSession_mintsExactlyOne`).
- [x] Wipe key correct: `defaultStorageKey = "supabase.auth.token"` (v2.55.0 `Sources/Auth/Internal/Constants.swift:17`); `SessionStorage.key` = `configuration.storageKey ?? defaultStorageKey`; WePark builds `AuthClient` directly and never sets `storageKey`, so the key is exactly `SupabaseClients.sessionStorageKey`. The key is not derived from the project URL in this SDK (that scheme belongs to other clients), so there is no per-URL derivation to get wrong. `testSessionStorageKey_matchesSDKDefault` is a real test: it signs up through the real `AuthClient` and asserts the blob exists under that key. The wipe goes through the same `localStorage` object the client uses.
- [x] Wipe is guarded to the deleted user: only runs if `currentSession.user.id == deletedUserId`, so a replacement stored by the handler first is never removed.
- [x] Exactly ONE mint under both orderings, by walking the main-actor interleavings: if the handler task runs first it creates `pendingSignIn`; `endSession` then finds `currentSession` nil (mint in flight), calls `clearSession()` + `signInAnonymously()` which JOINS the in-flight task. If `endSession` runs first, the handler later either joins the in-flight task or (mint finished) adopts the stored session. `adoptOrMintReplacement` has no `await` between its check and the mint call. `testEndSession_replacesIdentityBeforeReturning_exactlyOneMint` asserts `signupAttempts == 2` after settling.
- [x] Offline: no session, no loop. After the SDK removal, up to two sequential failed mint attempts are possible (handler + `endSession`); a failed mint creates no user. `testEndSession_mintOffline...` bounds this at 3 total and asserts no background retry. Next write recovers via `validAccessToken()`.
- [x] Revoked-marker lifetime: in-memory, never cleared, process-lifetime (see above). Acceptable.
- [x] What the user sees: sheet closes, new anonymous identity, `CommunityIdentityGate.shownKey` cleared by `AccountDeletionLocalState`, and `CommunityIdentityGate().shouldShow()` is evaluated fresh from `UserDefaults` at each call site (ReportSheet, BlockDetailView, CrewFeedSection, ParkedCarDetailView), so the identity sheet is offered on the next contribution.
- [x] Snapshot consistency: token + user id from one `Session` value; `deleteAccount()` uses the snapshot id for the listing prefix, the cross-check, the RPC JWT and the revoked id (`testSnapshotUserId_drivesPrefix_andSignout`).

**Y3 - stale state**
- [x] `CrewFeedProfileState` keyed to `ownerId`; `syncIdentity` drops on any owner change including to nil; `needsLoad` requires a user and a same-owner prior attempt; mid-flight identity change never publishes the old user's profile. Task key includes the user id; `.onChange` clears profile and leaderboard immediately. Eight value-type tests.
- [x] `RegularsService` resets edges, notices, loading flags and errors on `.weParkAccountDeleted`. Posted only after success: `deleteAccount()` posts after `endSessionAfterAccountDeletion` and `clearLocalState()` and nothing throws after that point; `testSuccess_postsNotification_afterLocalClear`, `testFailure_doesNotPostNotification`.
- [x] `PushRegistrationService` dedupe key includes `userId` (`UploadKey(... userId: authService.currentUserId)`, line ~582); a new identity re-uploads on the next foreground/zone change. No in-process trigger fires at deletion time, so the new user's token row appears on the next trigger (documented; smoke step below).
- [~] Other per-user in-memory caches. I grepped every `currentUserId` reader. The only per-user cached state is the crew feed profile (fixed), `RegularsService` (fixed), and the already-fetched `CommunityPin`/`ZoneMessage` rows in `CommunityPinService`/`ZoneMessageService` (the builder's known non-fix). The rest compute from `currentUserId` at render time (`reactionsRowKind`, `claimStatusCopy`, `PinDetailSheet`, `BlockDetailView`) and so flip to the new identity automatically. No outbox, vote-history or reputation cache exists. See 🟢 #G4 for the stale-pins judgement.

**🟢 items**
- [x] Lost RPC response: transport error -> `accountDeletionFailed`, copy says "safe to retry", no sign-out, no notification (`testRpcTransportError_isRetrySafeFailure_andDoesNotSignOut`, `testLostRpcResponse_thenRetry_succeeds`). Retry after a committed deletion: if the stored JWT is still unexpired, the RPC is an idempotent no-op returning 2xx (per the SQL header) and the handoff proceeds; if the refresh token is dead, `currentSessionSnapshot()` mints a new anonymous user and the retry deletes that empty user then mints another (harmless; the user sees success).
- [x] 401-as-success only with GoTrue confirmation: see #G3 for why this branch is practically unreachable and what it would take to be wrong.
- [x] Confirm-sheet copy: new row "Your parked car and reminders on this device are kept. WePark keeps working, with a fresh anonymous profile." No avoid/ticket/fine/evasion/dodge in added lines. Destructive confirm and Cancel still `minHeight: 56` (lines 214, 226); the new row uses the existing `consequenceRow` in the scrollable stack.
- [x] Flag doc comment accuracy: "photos first, RPC last; migration 12 missing aborts before the RPC (nothing lost); migration 10 missing destroys photos, keeps account, every retry errors at the RPC" is correct (12 missing: removal returns 200 with `[]`, shorter than sent, abort; 10 missing: rows survive so retry probes -> not found -> RPC fails). Stale-header fix in `SupabaseAuthService` (no user-visible sign-out; only caller is deletion) is accurate.
- [x] Test quality: every test class touching MainActor APIs is `@MainActor` (the earlier CI host crash class); the mock `URLProtocol`s are per-file private classes with a static handler that each test overwrites before use, tests run serially, and each builds its own ephemeral `URLSession`; the real-SDK tests use `InMemoryAuthStorage` (never the Keychain), so no Keychain item or global state is left for other tests or a device install. One note: `testAccountDeletedNotification_resetsRegularsService` posts on `NotificationCenter.default`, which also resets any live `RegularsService` in the test host. Harmless.

**Scope**
- [x] Diff touches exactly 9 files: `AccountDeletionService`, `Constants` (comment), `RegularsService`, `SupabaseAuthService`, `SupabaseClients`, `AccountDeletionView`, `CrewFeedSection`, and the two test files. `ContentView.swift`, `SuggestNeighborhoodSheet.swift`, `PinEvidenceUploader.swift`, SQL and `project.pbxproj` untouched. `accountDeletionEnabled = false` (Constants:283), `coverageRequestsEnabled = false` (296). No schema change.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant (fix or live-verify BEFORE flipping `accountDeletionEnabled`)

- **#S1: Strict not-found recognition can permanently trap a user whose first attempt failed after removing photos.**
  - Where: `AccountDeletionService.isObjectNotFound(status:body:)`.
  - What: accepts only (400|404) with `code == "NoSuchKey"`, or `error == "not_found"` AND `message == "object not found"` (case-insensitive). Any other body for a genuinely missing object (for example `{"statusCode":"404","error":"NoSuchKey","message":"Object not found"}`, or `"error":"Not found"` with a space on older servers) is read as "inconclusive" and aborts. This does NOT make every deletion fail: probes only run for `pin_evidence` rows missing from the listing, which in a normal first-time deletion is none. It bites exactly the retry-after-partial-failure case (photos gone, RPC failed, rows remain): every retry probes, gets an unrecognised "missing" answer, aborts with "couldn't remove your photos", and there is no other escape. Fail-safe for data, but that user can never delete their account (an App Store 5.1.1(v) problem).
  - Expected: positively recognise Storage's missing-object answer across body variants. The `message` text is the most stable discriminator and is already safe against the dangerous look-alikes (missing bucket says "Bucket not found", unknown route says "Route ... not found", bad JWT says something about the token): accept (400|404) with `message.lowercased() == "object not found"` OR the two current forms, keep failing closed on everything else.
  - Repro / gate: on the Mac, with a throwaway user, `curl -i -H "Authorization: Bearer <jwt>" -H "apikey: <anon>" "$URL/storage/v1/object/info/authenticated/pin-evidence/<uid>/<group>/does-not-exist.jpg"` and compare status+body to the strings above; also run the retry scenario end to end (remove files, force the RPC to fail, retry). Not verified live by me.
  - Owner: `@ios-engineer`.

### 🟢 Minor / nit

- **#G1: Evidence-rows pagination depends on PostgREST `max-rows >= 1000`.** The loop stops when a page has fewer than 1000 rows. If the project's `max-rows` were lower than 1000 (Supabase default is 1000), the first page would be "short" and the rest silently skipped, narrowing the cross-check (fail-open on the unchecked rows). Practically unreachable (photo reports are rate-limited), but looping until an empty page costs one cheap request. Owner: `@ios-engineer`.
- **#G2: `.signedOut` with a swallowed storage-delete failure now adopts the stale session instead of minting.** Old handler minted a new user that overwrote the stale one. Now the stale session is adopted for display; the next write's `validAccessToken()` fails the refresh and falls through to `signInAnonymously()`, so it self-heals without a loop. Only reachable on a double fault (refresh failure plus Keychain delete failure). No action required; noted because it is the one place the shared routine is not byte-equivalent for a non-deletion `.signedOut`.
- **#G3: The 401-as-success branch is effectively unreachable, and its `session_not_found` leg is the only way it could be wrong.** A 401 from PostgREST on the RPC means an expired/invalid JWT; GoTrue then answers `GET /auth/v1/user` with 403 `bad_jwt`, not `user_not_found`, so the confirmation fails and the call is treated as a failure (correct). GoTrue's real shapes for a valid-signature token are 403 `user_not_found` ("User from sub claim in JWT does not exist") and 403 `session_not_found`; a valid unexpired JWT would not get a 401 from PostgREST in the first place. Mistaken success needs a 401 AND a 403 `session_not_found` for a user that still exists; I could not construct a realistic path. Consider dropping the `session_not_found` leg for tidiness. Not verified live.
- **#G4: Already-fetched pins/chat keep the deleted user's name and `authorId` on screen until the next refetch.** Judgement: acceptable to ship dark. The name is only shown on the user's own device (no other user sees it; server rows are already de-attributed and read "Former neighbor" for everyone else). Side effect: `reactionsRowKind` compares the stale `authorId` with the new identity, so the user's old pins briefly render as someone else's (react row instead of delete). Cheap follow-up before the flag flip: have the pin/chat services refetch on `.weParkAccountDeleted`. Owner: `@ios-engineer`.
- **#G5: The probe is RLS-scoped, so "not found" also means "not visible to me".** It cannot catch an object the caller's own select policy hides. Only matters for a path whose first segment is not the lowercase uid, which the uploader and INSERT policy make impossible. Informational.
- **#G6: Minor behaviour deltas in the crew feed on nil -> id.** One extra leaderboard load and one leaderboard clear when the first anonymous mint lands while the crew feed is already open (cold-start edge). Intended (it is the retry the old comment promised). Informational.
- **#G7: Stale header text** `AccountDeletionService.swift` still carries "[COMPILE-UNVERIFIED] Written on a Linux VPS"; CI has now compiled and run it. Cosmetic.

### 💡 Out of scope (logged, not fixed)
- `pins_with_author` parked_car leak (PR #139 QA), open-items.md status rows (orchestrator).
- The pre-existing zone-switch-cancels-profile-fetch quirk in `CrewFeedSection` (unchanged by this PR).

## Smoke tests run

- `gh run view 40039583827` (conclusion, sha match, test counts, per-suite pass lines): green, 2004/0.
- Read the full diff of all 9 files and the complete `AccountDeletionService.swift`, the changed `SupabaseAuthService` regions, `CrewFeedSection` changes, `RegularsService` changes.
- Fetched supabase-swift v2.55.0 and read `AuthClient.signOut`, `SessionStorage`, `APIClient.handleError`, and `Internal/Constants.swift` to confirm signOut ordering, the storage key, and when the SDK itself emits `.signedOut`.
- Traced main-actor interleavings of handler vs `endSessionAfterAccountDeletion` for single-flight; cross-checked against the 8 real-SDK tests (read in full).
- Grepped every `currentUserId` reader and all `CommunityIdentityGate().shouldShow()` call sites for stale per-user state; confirmed `storage_path` format against `PinEvidenceUploader`; confirmed flags `false` and scope by `git diff --name-only`.
- Not run: simulator, live Supabase, real Keychain failure.

## Mac smoke list - the PR's, plus additions

0. Preconditions: ceremony Q0 passes, migrations 10 AND 12 applied, Q1 passes. Throwaway account only. Never flip the flag first.
1. **`curl` the info route** for a deleted object and a live object (commands in #S1); record exact status and body for both. Decide on #S1 from the result.
2. Throwaway account with photos in two report groups: delete; confirm `storage.objects` for `<uid>/%` is 0, `pin_evidence` rows gone, `auth.users` row gone.
3. **Exactly one new anonymous user** created in `auth.users` since the run started (not two).
4. **Token never served after deletion:** after success, a community write (vote/report) is performed as the NEW user (check `author_id`/`auth.uid()` on the row); no request after deletion carries the old user's JWT (proxy or Supabase API logs).
5. Retry-after-partial-failure: force the RPC to fail once after photos are removed (point at a 500 locally), then retry; must succeed (exercises #S1).
6. Airplane mode at confirm: friendly error, account intact. Airplane mode toggled right after success: app is on no session; the next write (back online) mints one.
7. **Crew feed after deletion** (open while deleting, and reopened): no deleted profile/rank shown, identity sheet offered on first contribution, new identity's profile loads.
8. Push: `device_push_tokens` row for the new user appears after a foreground/zone change.
9. **Place-card detent** with the "Suggest this area" row (flag on locally) in the browse sheet; flag-off card unchanged.
10. Flag-off regression pass on a real install: cold launch (one anonymous user created on a fresh install), airplane-mode cold launch then reconnect, background > 1h then foreground (token refresh, no new user), crew feed opens with profile card for a returning user.

## What's working

- The handoff is genuinely deterministic: one routine shared by two callers, single-flight underneath, idempotent against an existing replacement. The SDK-ordering assumption was checked against source and holds.
- The wipe key is pinned by a test that exercises the real SDK write path, and the wipe is scoped to the deleted user only.
- Fail-safe posture throughout: every inconclusive answer (probe, rows query, 401 confirmation) aborts rather than proceeds.
- Normal deletions add zero requests beyond the rows query, since probes only run for rows missing from the listing.
- Tests assert cross-component ordering and negative cases (no second mint after settling, no notification on failure) rather than tautologies, and avoid the Keychain and shared URLProtocol state.
- Dark-ship discipline held: flags false, scope limited to named files, doc comments corrected to match behaviour.
