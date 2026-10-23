# PR #144 QA Pass 1 - Account deletion (#38) + Suggest a neighborhood (#39), iOS side

**Reviewed:** branch `feat/account-deletion-and-suggest-neighborhood` at `0ed4cfc6`, against `supabase/10-account-deletion.sql`, `11-coverage-requests.sql`, `12-storage-delete-own.sql`, `docs/supabase-ceremony-10-11.md`, `docs/qa/pr139-account-deletion-coverage-requests.md`.
**Verdict:** MERGE (dark-shipped). No blocking defect found. Both flags ship `false`, so merging changes no live behaviour. The 🟡 items below should be fixed or consciously accepted BEFORE either flag is flipped, and the Mac smoke (below, amended) is the gate for the flip, not for the merge.

## Hard limits of this review (read first)

- **No Swift toolchain here.** Nothing was compiled or run. Every claim about compilation is from reading the code against the repo's six known failure classes and against merged precedent.
- **I could not exercise the real Supabase Storage list/remove API.** The prefix judgement (finding Y1) is from my knowledge of storage-api and supabase-js, with a stated confidence, not from a live call.
- **I could not read the pinned supabase-swift (v2.55.0) source.** The claim that `signOut(scope: .local)` removes the stored session and emits `.signedOut` before its network call is the builder's; it matches my memory of recent versions but is unverified here.
- No mount-chain files (`ContentView`, `MapViewRepresentable`, `Views/DriveMode*`, `.safeAreaInset` code) are touched (`git diff --stat` confirms `ContentView.swift` unchanged), so the live-UI screenshot rule does not apply to this PR. The new views only render when a flag is on; they need the Mac smoke when the flags are flipped locally.

## Summary

The deletion sequence is correct and fail-safe: the RPC call is structurally unreachable after any list or removal failure, a short or undecodable removal response aborts, the model's double-tap guard flips phase before the first suspension, and every prefix goes through one lowercasing helper that is tested. The builder's "bare `<uid>` list prefix" deviation is the right call (details below). The remaining risk is concentrated in (a) the one remaining way to orphan photos (a list that silently returns `[]`) which has no runtime guard and relies on a manual smoke, and (b) the post-deletion local-identity handoff, which touched the identity-critical `SupabaseAuthService.swift`/`PushRegistrationService.swift` with no test.

## Acceptance checklist

**Deletion sequence (priority 1)**
- [x] List then remove then RPC, in that order; RPC only after every removal succeeded. `deleteAccount()` wraps steps 1-2 in one `do/catch` that rethrows `.photoCleanupFailed`, so control cannot reach `callDeleteRPC` after any error in them. Verified by reading `AccountDeletionService.swift:227-260`, and `testRemovalHttpFailure_abortsBeforeRpc`, `testRemovalShortReturnedList_abortsBeforeRpc`, `testListFailure_abortsBeforeRpc` assert `rpc` is absent from the event log.
- [x] Short-returned-list handling. `removed.count >= paths.count` else abort; undecodable body aborts. This also makes "migration 12 not applied" fail safe: the Storage API answers 200 with `[]` when RLS denies the delete, which is `0 < n` and aborts. Good catch by the builder.
- [x] Pagination terminates. Loop breaks on a short page; full page then empty page does one extra request and stops (tested); hard caps (`maxListPages` 500, `maxFolderDepth` 4) bound a misbehaving server. Offset math (`offset += page.count`) is right with default `name asc` ordering. Caps themselves are untested (🟢 #G3).
- [x] Batching: 100 paths per `DELETE` (tested 100/100/30).
- [x] Double-tap and re-entrancy: `confirmDeletion()` guards on `isIdle` and sets `.deleting` synchronously; button disabled and replaced by spinner; sheet `interactiveDismissDisabled` while deleting; run is an unstructured `Task` so it survives the view going away. Tested (`testConfirmDeletion_doubleTap_runsOnce`).
- [x] Partial failure then retry: a retry re-lists only what is left; a retry where everything was already removed lists `[]`, skips removal, calls the idempotent RPC. Correct by construction; **no test** pins "first run removed some files, retry succeeds" (🟢 #G3).
- [x] Token expiry mid-sequence: one JWT is fetched at the start and reused. Expiry produces a 401 on a later step which maps to a safe abort and the retry fetches a fresh token. Fail-safe, not a bug. A multi-minute sequence would only occur for an enormous account.
- [~] Backgrounding mid-deletion: no `beginBackgroundTask`. Suspension mid-request yields a network error, which is a safe abort or a lost RPC response (see Y3). Acceptable.
- [ ] "List silently returns `[]` although objects exist": **no runtime guard**. See Y1.

**Other criteria**
- [x] Lowercase everywhere: single helper `storageRootPrefix(for:)` = `uuidString.lowercased()`; nested paths are rebuilt from that prefix plus server-returned names (filenames are uppercase `UUID().uuidString` from the uploader; preserved as returned, correct). Tested (`testStorageRootPrefix_isLowercase`, wire-level lowercase asserts). `PinEvidenceUploader.swift` is untouched in the diff; its lowercase fix from `e851e51f` is intact.
- [x] Flags default `false` (`Constants.swift:280,293`) with guard tests; the only read sites are `SettingsView` (two `if`) and `BrowseSearchAreaView` (one `if`), all through the gating functions. Flag-off: no Section, no row, no `.sheet` modifier is attached (the delete sheet lives inside `AccountDeletionSection`, the suggest sheet inside `suggestAreaRow`, both only mounted flag-on). `@State showSuggestSheet` is the only always-present addition to `BrowseSearchAreaView`.
- [x] `ContentView.swift` untouched. `WeParkApp.swift` adds `.environment(authService)`; consumers use `@Environment(SupabaseAuthService.self) var x: SupabaseAuthService?` (the optional-reading overload), so previews/tests/other entry points get `nil` and the row is `.disabled`, not a crash. No side effects for existing views (nothing reads the environment value today). Environment flows into the Settings sheet and the browse sheet because both are SwiftUI sheets.
- [x] "Former neighbor" rule is exactly as specified: `username` wins; else `authorId == nil && isUserAuthored` gives "Former neighbor"; else "Neighbor". Pins: `source == .crowd` via pattern match; chat: `messageType == .user`. Open-data/hybrid pins, `system_tracker` lines, and live authors with an unjoined username (Realtime INSERTs, "Neighbor" as today) are unchanged. Not flag-gated; behaviour change is limited to NULL-author crowd/user rows, which only exist after a deletion (client inserts always set `author_id`; seed/open-data pins are `open_data`). Checked other readers of `authorUsername`: only `CrewFeedSection` (pin + chat sub-lines, leaderboard which skips nil authors) and `BlockChatRow`; there is no separate pin-detail author label to keep in sync. Existing test renamed correctly; no other test asserts "Neighbor".
- [x] Suggest: `Prefer: return=minimal` (test), body is exactly `city`/`note`/`viewed_lat`/`viewed_lng` with note and coords omitted when nil (test), never `user_id`/`id`/`created_at`; coordinates come from the searched destination (never GPS), rounded to 2 dp client-side, both-or-neither enforced, Settings entry sends none; 42501 with `rate limit exceeded` prefix maps to one neutral message for both per-user and global texts (tested with both), other 42501 is not rate-limited, 23514 maps to inline copy, `URLError` maps to network; uses `validAccessToken()` (the existing anonymous session, mints one if absent); phase flips before suspension (double-tap tested).
- [x] Client validation vs SQL normalization: the Swift blank class (`0009-000D, 0020, 0085, 00A0, 00AD, 1680, 180E, 2000-200F, 2028-202F, 205F-206F, 3000, FEFF`) is character-for-character the SQL `v_blank` class. Trim at edges only; minimum counts non-blank scalars everywhere; maximum counts all scalars of the trimmed string; code points via `unicodeScalars`. Edge cases agree with SQL: 2-char CJK city accepted (2 visible); all-ZWSP rejected; "A" + ZWSP rejected after trim; "A B" accepted (min counted with blanks removed); ZWJ family emoji is 5 scalars (3 visible) so 16 fit in 80 and 17 do not; note padded past 500 with blanks is trimmed first. All covered by tests.
- [x] Copy: confirm sheet states what stays (pins/chat, "Former neighbor") and what is deleted (profile, notification registrations, votes, evidence photos) and "This can't be undone". Banned-word grep on added lines finds only "fine" in a code comment and "evasion" in a code comment; no user-facing string contains avoid/ticket/fine/evasion/dodge. Destructive confirm and Cancel are `minHeight: 56`; Settings rows 48; Submit 56; scrollable, no fixed-height text; decorative icons `accessibilityHidden`; hints on the destructive controls; error text has an "Error." accessibility label.
- [x] Project registration: new files live under the synchronized root groups (`objectVersion 77`, `PBXFileSystemSynchronizedRootGroup`); no `pbxproj` edit needed or made.
- [x] Six compile-failure-class scan (reading only): (1) no literal-receiver chains found; (2) memberwise/labelled calls checked against declarations - `UploadKey(tokenHex:environment:zoneId:userId:)` in declaration order at both sites, `CoverageRequestDraft(city:note:viewedLatitude:viewedLongitude:)`, `AccountDeletionService(supabaseURL:supabaseAnonKey:urlSession:session:clearLocalState:)`, `SuggestNeighborhoodModel(viewedLatitude:viewedLongitude:submitter:)` all match; (3) helper names in both test files are `acctDel*`/`covReq*`/`AcctDel*`/`CovReq*` and all `private`, no repo-wide collision (grep); (4) MainActor default isolation: value types used from `nonisolated` code are marked `nonisolated` (`CoverageRequestDraft`, `CoverageRequestRules`, `CoverageRequestError`), `AuthorDisplayName` reads `let` fields of `CommunityPin`/`ZoneMessage` from `nonisolated` statics, which is the same pattern as merged `CommunityPinService.isChannel1Member(_:)`, and the gating functions copy `regularsSettingsRowVisible(enabled:)` exactly; `AccountDeletionError` is not `nonisolated` but is identical in shape to merged `PinEvidenceUploadError`; no `==` on nested enums in `nonisolated` code (pattern `if case` used); (5) test-target isolation: the `WeParkTests` build settings in `project.pbxproj` carry NO `SWIFT_DEFAULT_ACTOR_ISOLATION` (only the app target has `MainActor`), so test files are nonisolated by default; the builder's choice to annotate every test class that touches app-side MainActor APIs `@MainActor`, and to leave the pure-rule test class (`CoverageRequestRulesTests`) unannotated because it only calls `nonisolated` statics, is correct; (6) no bare `Category`, no `Calendar.current`, no SwiftUI import under `Services/`, only Foundation. Residual: first compile is still the Mac's.

## Findings

### 🔴 Blocking
None.

### 🟡 Significant (fix or accept explicitly before flipping `accountDeletionEnabled`)

- **Y1: Nothing at runtime stops "list returned `[]` but photos exist" from letting the RPC orphan files.**
  - Where: `AccountDeletionService.deleteAccount()` / `listAllPages`.
  - What: step 3 is gated only on "removals did not fail". An empty listing is indistinguishable from "no photos". The mitigation today is the prefix choice plus one manual smoke run.
  - On the prefix itself (builder's flagged deviation): **bare `<uid>` is the right choice; confidence about 90%.** storage-api's list handler treats the `prefix` body field as a folder: in current code the object layer appends a trailing `/` only if the prefix is non-empty and does not already end in `/` (it then calls the `storage.search` SQL function with `levels` derived from the slash count). supabase-js `list('folder')` documents and sends the bare folder name, so bare is the best-trodden path across server versions. `<uid>/` also works on current servers (the ceremony doc's curl uses it), so the SQL header's example is not wrong today; the risk the builder describes is a hypothetical unconditional-append server, and bare is correct under both behaviours. Results are relative names (supabase-js documents this); sub-"folders" are returned with `id: null` and null metadata, which the code correctly recurses into and never adds to the removal list (a folder name is not an object path; the order test pins that only file paths reach `prefixes`). Default sort is `name asc`, so offset paging is stable.
  - Expected: a cheap independent cross-check so an unexpectedly empty listing cannot silently pass. **Feasible**: the user can SELECT their own `pin_evidence` rows (`pin_evidence_select_own`), so `GET /rest/v1/pin_evidence?select=storage_path&uploaded_by=eq.<uid>` tells the app what should exist. Do NOT implement it as "rows exist but listing is empty, abort": that deadlocks the retry after a first run removed the files but the RPC failed (rows only disappear in the RPC). Instead, for each row path NOT present in the listing, probe the object directly (authenticated `GET /storage/v1/object/info/pin-evidence/<path>` or a ranged GET); abort only if a probe says the object still exists. That is retry-safe and catches a bad prefix.
  - Alternative if the owner prefers to stay minimal: keep as is, but make the Mac smoke stricter (below), including a two-group account and running both prefix forms by curl before the flag flip.
  - Owner: `@ios-engineer`.

- **Y2: The post-deletion identity handoff changed `SupabaseAuthService.swift` and `PushRegistrationService.swift` with no test, and has an ordering gap.**
  - Where: `SupabaseAuthService.endSessionAfterAccountDeletion()` (lines 175-197), `PushRegistrationService` `UploadKey`/`upsertToken`.
  - What: (1) The method calls `signOut(scope: .local)`, then awaits `pendingSignIn` only if it is already non-nil. The `.signedOut` event is consumed by a separate `Task` hopping to the MainActor, so there is no guarantee the handler has run (and set `pendingSignIn`) by the time `signOut` returns; the "callers see a settled identity" comment is not guaranteed. Consequence is small (a window of milliseconds in which `currentUserId` still holds the deleted uid, and a write in that window would hit FK 23503) but the claim and the code disagree. (2) If the SDK's `signOut` threw before removing the stored session (the builder's "removes first" claim is unverified here), the failure is swallowed by `try?` and the app silently keeps the deleted user's session until the access token expires (up to 1 h) and refresh fails. (3) The repo already has a real-SDK test seam (`SupabaseAuthService(supabaseURL:supabaseAnonKey:testStorage:fetch:)`, used by `PushRegistrationServiceTests`), so a test with a mocked `/logout` (401) and `/signup` is cheap and was not written.
  - Expected: after `endSessionAfterAccountDeletion()` returns, `currentUserId != deletedUserId` (or nil) and exactly one anonymous sign-up request was made, tested; and a defensive fallback if `currentUserId` still equals the deleted id (clear it and let the existing coalesced `signInAnonymously` run - do not add a second mint path without the coalescing).
  - The `PushRegistrationService` change itself is behaviour-preserving: `lastUploaded` now records the id actually used, and a candidate evaluated with `userId == nil` still dedupes next time because `upsertToken` guarantees a non-nil id. One benign difference: at cold launch an attempt evaluated before the session exists and a second one after it exists now have different keys, so one extra idempotent merge-duplicates POST is possible (🟢 #G4). Existing push tests construct the real auth service and do not name `UploadKey`, so none should break.
  - Owner: `@ios-engineer`.

- **Y3: Stale in-memory per-user state after deletion is unverified.**
  - Where: `CrewFeedSection` (`@State currentProfile`, `hasAttemptedProfileLoad`, lines ~605-615, 848-851), `RegularsService` (app singleton, flagged off).
  - What: the deleted user's profile card/rank can persist in already-mounted views, and `hasAttemptedProfileLoad == true` stops the new identity's profile from being fetched until the view is recreated. If the crew feed is re-created on each open this is moot; I could not confirm without running the app. `AccountDeletionLocalState` correctly clears the persisted identity-sheet gate, but that only helps if the views also reset.
  - Expected: after deletion the next community write shows the identity sheet and no deleted-user profile is displayed.
  - Repro: Mac smoke step 7 below. Not verified - recommend live smoke before flipping the flag.
  - Owner: `@ios-engineer`.

### 🟢 Minor / nit

- **G1: The user-visible failure copy cannot distinguish "response lost after the server committed".** If the connection drops after `delete_my_account()` commits, the user sees "couldn't delete your account" although it succeeded; the app keeps a zombie session. Retry is safe (idempotent RPC; if the refresh token is already dead, `validAccessToken()` mints a new anonymous user and the retry deletes that empty one, then mints another). Harmless but worth one line in the smoke notes.
- **G2: Photos are destroyed before the RPC, so flag-on with migration 10 missing destroys photos and leaves the account.** The doc comment on the flag says the flow "aborts before/at the RPC ... account is left intact" - true for the account, not for the photos. Sequence is mandated by the contract; just make sure the flag is only flipped after ceremony queries Q0/Q1 pass, and fix the comment.
- **G3: Test gaps.** No test for: partial-removal then retry; `maxListPages`/`maxFolderDepth` bounds; a nested-folder depth case; `ID` mismatch between JWT subject and `currentUserId`. Also `AccountDeletionLocalStateTests` uses an isolated suite (good) but the production `clear()` default path is not asserted to remove the key from `.standard`.
- **G4: Cold-launch extra push upsert** (see Y2) - idempotent, harmless.
- **G5: `uid` taken from `currentUserId`, token from `validAccessToken()` separately.** If the two ever disagree (a racing sign-in), the listing would be for a different uid than the JWT's, would return `[]` under RLS, and the RPC would delete the JWT's user with their photos orphaned. Very narrow, but deriving the uid from the JWT `sub` removes it (and pairs well with Y1).
- **G6: Suggest affordance polish.** The sheet's city field is not prefilled from `resolvedName`; the extra row grows the place card in the browse sheet, which may change detent fit when the flag is on (flag-off unaffected). Check on device.
- **G7: Confirm copy** does not say parked car and reminders on this device are kept, or that the app will continue on a fresh anonymous identity. Optional.
- **G8: Stale header** in `SupabaseAuthService.swift` still says no sign-out is exposed (the PR notes this).

### 💡 Out of scope (logged, not fixed)
- `pins_with_author` parked_car leak from the PR #139 QA (separate migration decision).
- open-items.md status rows for #38/#39 (orchestrator).

## Smoke tests run

- Fetched the branch, read the full diff (16 files, +2894/-7) and every new/changed file in full except the unchanged remainder of `BrowseSearchAreaView`.
- Read SQL headers 10/11/12, the ceremony doc, and the PR #139 QA; cross-checked every iOS request shape (paths, bodies, headers, `Prefer`) against them.
- Confirmed by `git diff --stat`: `ContentView.swift`, `PinEvidenceUploader.swift`, `project.pbxproj` unchanged.
- Confirmed flag defaults, all read sites, and gating-function precedent by grep.
- Confirmed test-target isolation settings in `project.pbxproj`; confirmed no repo-wide collision of test helper names; confirmed no other test asserts the old "Neighbor" fallback.
- Not run: build, tests, simulator, live Storage. Nothing here substitutes for the Mac.

## Mac smoke checklist - what the PR lists, plus what is missing

PR's steps 1-4 are good. Add:

0. **Preconditions, in order:** ceremony Q0 (pre-check) passes, 10, 11, 12 applied, Q1 passes. Never flip either flag before.
1. Before the app run, with curl and a throwaway user that has files in TWO report-group folders: list with prefix `"<uid>"` and with `"<uid>/"` and confirm both return the group folders (`id` null) and that listing a group with and without the trailing slash returns the files. This turns Y1 from "90% confident" into measured fact on this project.
2. `xcodebuild test` green, with specific eyes on the new files for the six compile classes.
3. Throwaway deletion run as PR step 4 (never a real account), but seed it with: one photo report, 101+ files if feasible (exercises paging/batching - or temporarily lower page size locally), and a second group folder. After deletion: `select count(*) from storage.objects where bucket_id='pin-evidence' and name like '<uid>/%'` must be 0 (the PR has this; keep it as the pass/fail), plus the standing orphan query from the ceremony doc returns 0 rows, plus `auth.users` row gone.
4. Failure paths on device: airplane mode before confirming (friendly error, nothing changed, account still works); airplane mode toggled on right after photo removal is hard to time, so instead temporarily point the RPC path at a 500 locally and confirm the app stays signed in and the retry succeeds.
5. What the user sees after success: sheet closes, Settings closes, toast "Your account was deleted", app continues; `auth.users` shows exactly ONE new anonymous user (not two) created since the run started.
6. After deletion: the device's push token row is re-created for the new user (`device_push_tokens`) after a foreground/zone change.
7. After deletion: open the crew feed and the identity prompt - confirm the deleted profile/rank is not shown and the community identity sheet is offered again on the first contribution (Y3).
8. Suggest: with flag on locally and migration 11 applied, submit once (201, row stored with 2-dp coordinates), then rapid-submit to trip the limit and confirm the neutral copy; confirm from Settings nothing is sent for coordinates.
9. Flag-off regression pass: Settings has no Coverage/Delete rows; the browse place card is visually unchanged for an in-coverage and an out-of-coverage destination.

## What's working

- The abort-before-RPC structure is airtight and the tests assert real cross-component ordering through a shared event log, not tautologies.
- The "short removal list = failure" rule quietly covers the "migration 12 not applied" case.
- Lowercasing is centralised, tested, and the uploader fix is not regressed.
- Client-side validation mirrors the SQL class exactly, including the code-point (not grapheme) counting that the PR #139 QA stressed.
- The "Former neighbor" rule is narrow and matches the SQL contract's warnings (open-data pins, system lines, unjoined live authors all keep "Neighbor").
- Dark-ship discipline: gating functions follow the repo precedent, and sheets are attached only inside flag-gated views.
- The builder disclosed the prefix deviation and the `PushRegistrationService` edit instead of burying them.
