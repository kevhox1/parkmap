# supabase-swift Auth/Keychain Stream A — QA Pass 1 — 2026-08-13

**Reviewed:** branch `ios/supabase-auth-keychain-stream-a` at `130af57c` (merge-base with `main`:
`5e33c141`), against `docs/supabase-swift-realtime-spec.md` §9, §11 (Stream A / AC-A1–AC-A5), and PR #77's
own description.
**Verdict:** 🟡 ship with caveats — contingent on the Mac `xcodebuild build`+`test` gate the PR itself
requires (not yet run; this review is entirely source-level) and one significant test-coverage gap that
should be closed before or immediately after merge (see Finding #1).

## Summary

This is unusually well-verified "compile-unverified" work. All three self-flagged SDK uncertainties in the
PR description, and the claimed pre-ship bug catch (storage decoder vs. network decoder mismatch), check
out exactly against the real pinned `supabase-swift` source at `a71f55a8d522aa38e2cecd314b64c6b24d518f8c`
(2.55.0) fetched fresh from GitHub for this review — including a byte-for-byte match between this PR's
`.signedOut`-triggering test fixture and supabase-swift's own upstream test for that exact scenario. Scope
discipline (no `CommunityPinService.swift` diff, no `pbxproj` diff, `CURRENT_PROJECT_VERSION` still 16, only
`Auth`+`Realtime` linked) is independently confirmed, not just claimed. The one real problem: of the 5 tests
removed from `Tier3AuthReactionsTests.swift`, 4 have direct equivalents in the new `SupabaseAuthServiceTests.swift`
and 1 does not — the "session exists, is expired, refresh succeeds" path (the single most common
non-first-launch session state in production) now has zero test coverage. Net test count went up
(+1), which masks this loss unless you diff test *names*, not just counts — exactly the trap the task
brief was checking for.

## Acceptance criteria checklist (Stream A, spec §15)

- [x] **AC-A1** (byte-identical public API) — verified: `currentUserId: UUID?`, `isAuthenticated: Bool`,
      `validAccessToken() async -> String?` signatures unchanged; `WeParkApp.swift`'s diff is
      comment-only (confirmed via `git diff`, 16 added lines, all `//`); `CommunityPinService.swift` has
      zero diff (confirmed via `git diff --stat`, file absent from the change list).
- [x] **AC-A2** (Keychain, not UserDefaults) — partially verified. Source-level: `SupabaseClients.swift`'s
      `localStorage` param defaults to `AuthClient.Configuration.defaultLocalStorage`, which I confirmed by
      reading `Sources/Auth/Storage/AuthLocalStorage.swift` at the pinned revision resolves to
      `KeychainLocalStorage()` on Apple platforms. Negative-half test (`testKeychainNotUserDefaults_noLegacyKeysWritten`)
      is sound. **Not verified — no live Keychain round-trip exists in the test suite or was runnable on
      this VPS**; this is disclosed in the PR description as a deliberate omission (avoiding
      entitlement-flaky XCTest), not a silent gap. Recommend a manual on-device check post-merge (kill app,
      relaunch, confirm `currentUserId` persists — trivial smoke, not a formal test).
- [x] **AC-A3** (auto-resign on `.signedOut`) — verified at the source level in unusual depth (see Findings,
      "What's working"). The test's fixture (`error_code: "refresh_token_not_found"`, 403, no
      `X-Supabase-Api-Version` response header) is byte-identical to supabase-swift's own
      `AuthClientTests.removeSessionAndSignoutIfRefreshTokenNotFoundErrorReturned` test at the pinned
      revision — confirmed by direct comparison, not by trusting the PR's citation.
- [x] **AC-A4** (no `Calendar.current`) — verified by `grep`; zero matches in either changed production
      file, only comments reference the word.
- [ ] **AC-A5** (tests rewritten; legacy `UserDefaults` key constants removed) — **partially**. The old
      `Keys.*` constants are genuinely gone (`grep` confirms zero references outside comments). But "the
      previous `SupabaseAuthServiceTests` class... replaces them 1:1 in intent" (the new file's own header
      comment) is not quite true — see Finding #1. 4 of 5 removed tests have equivalents; 1 does not.

## Findings

### 🔴 Blocking
None. See the "what remains" note in the Summary — the one real gap (Finding #1) is real but not, in my
judgment, ship-blocking, for the reasons stated there.

### 🟡 Significant

- **#1: The "expired session, refresh succeeds" path has zero test coverage post-PR — a real, silent
  coverage loss, not a disclosed scope cut.**
  - Where: `ios/WePark/WeParkTests/SupabaseAuthServiceTests.swift` (new file, 6 tests) vs. the 5 tests
    removed from `ios/WePark/WeParkTests/Tier3AuthReactionsTests.swift`.
  - What: mapping the 5 removed tests to the 6 new ones:
    1. `testEnsureSession_noPersistedSession_callsSignIn` → covered by
       `testEnsureSession_noPersistedSession_signsInAnonymously`.
    2. `testEnsureSession_validPersistedSession_doesNotResignIn` → covered by
       `testEnsureSession_validPersistedSession_doesNotHitNetwork`.
    3. **`testEnsureSession_expiredToken_callsRefresh` → NOT covered. No equivalent exists.**
    4. `testSignIn_setsCurrentUserId` → redundant with #1 above; loosely covered by
       `testValidAccessToken_returnsCurrentSessionToken`.
    5. `testSignIn_httpFailure_doesNotSetUserId` → covered by
       `testEnsureSession_httpFailure_staysUnauthenticated`.
    The 2 genuinely new tests (`testAutoResignOnSignedOut_reestablishesAnonymousSession`,
    `testKeychainNotUserDefaults_noLegacyKeysWritten`) cover new behavior the old implementation didn't
    have — they don't backfill #3's gap. Net: 15 → 10 (file) + 6 (new file) = 16, a "+1" that reads as
    "coverage grew" unless you check test *identity*, not count — which is exactly what the task brief
    flagged as the risk to check for.
  - Why it matters: I traced this through the actual SDK source (`Internal/SessionManager.swift`,
    `Internal/APIClient.swift`) to confirm it's a real, reachable, everyday path — not a hypothetical.
    Every time WePark is reopened after the ~1hr access-token lifetime has passed (but the refresh token is
    still valid — the overwhelmingly common case, distinct from the "refresh outright fails" case
    `testAutoResignOnSignedOut...` covers), `SessionManager.session()` calls `refreshSession(_:)`, which
    POSTs to `/auth/v1/token?grant_type=refresh_token` and, on success, emits `.tokenRefreshed`. None of
    the 6 new tests exercise a *successful* refresh — only "no refresh needed" (valid, unexpired) and
    "refresh attempted and fails" (expired, refresh_token_not_found). The middle case — expired session,
    refresh succeeds, session is correctly restored — is untested.
  - Is this "genuinely untestable now" or "silently lost"? Silently lost, not untestable. The exact
    technique already used twice in this same file (seed storage via a real sign-in round-trip on a
    first `SupabaseAuthService` instance, then construct a second instance sharing that storage to
    simulate "relaunch") would work unchanged here — swap the seed's `expiresInSeconds` to something
    between 0 and `defaultExpiryMargin` (30s, confirmed from `Internal/Constants.swift`) and a plain
    negative value, and mock the `/token` endpoint to return 200 with a fresh session instead of 403.
  - Severity reasoning (why 🟡, not 🔴): the SDK's own refresh mechanics (`SessionManager.refreshSession`,
    including its `inFlightRefreshTask` dedup) are exercised by supabase-swift's own upstream test suite,
    not novel WePark code. And the worst-case failure mode if this path is silently broken — an unexpected
    fallback to `signInAnonymously()` producing a fresh anonymous identity instead of restoring the
    existing one — is the *exact same* outcome the PR's own no-migration-shim decision already declares
    acceptable at today's user count (Kevin, sole TestFlight user). It's real debt, cheap to pay down, and
    should be paid down before or immediately after merge — but it does not itself make this PR unsafe to
    ship.
  - Owner: `@ios-engineer`.

### 🟢 Minor / nit

- **#2: SDK's `emitLocalSessionAsInitialSession` is left at its default (`false`), which is the behavior
  the SDK's own authors call "incorrect" and plan to change.**
  - Where: `ios/WePark/WePark/Services/SupabaseClients.swift` — `AuthClient(...)` is constructed without
    setting `autoRefreshToken`/`emitLocalSessionAsInitialSession`, so both take their `Configuration`
    defaults (`autoRefreshToken = true`, `emitLocalSessionAsInitialSession = false`).
  - What: read `Sources/Auth/AuthClient.swift:1527-1560` at the pinned revision. With the default `false`,
    `emitInitialSession` calls `reportIssue(...)` on every real (non-test) app launch, with a doc comment
    reading verbatim: *"Initial session emitted after attempting to refresh the local stored session. This
    is incorrect behavior and will be fixed in the next major release since it's a breaking change... Check
    https://github.com/supabase/supabase-swift/pull/822 for more information."* `reportIssue` is
    suppressed in XCTest (`isTesting` gate), so this PR's own test suite never surfaces it, and it's very
    likely a soft console warning in production rather than anything crash-worthy — but it fires on every
    launch, is explicitly SDK-flagged as deprecated behavior, and this PR didn't opt in to
    `emitLocalSessionAsInitialSession: true` (which the SDK's own doc comment recommends).
  - Expected: not a spec requirement either way — flagging because it's a one-line change
    (`emitLocalSessionAsInitialSession: true` in the `AuthClient.Configuration`/`AuthClient` init call) that
    both silences the noise and gets ahead of a documented upstream breaking change, and because it also
    slightly changes the initial-session race shape described in Finding #1/#3 below (worth re-examining if
    it's changed later).
  - Owner: `@ios-engineer`, non-blocking, fold into the next Auth-touching PR.

- **#3: `SupabaseAuthServiceTests.swift`'s doc comment overstates "replaces them 1:1 in intent."**
  - Where: `ios/WePark/WeParkTests/SupabaseAuthServiceTests.swift`, header comment.
  - What: the header says the new file "replaces [the 5 old tests] 1:1 in intent." Per Finding #1, this is
    4-for-5, not 5-for-5. Low severity on its own (a doc-comment accuracy nit), but I'm flagging it
    separately from #1 because an inaccurate "1:1" claim in a comment is exactly the kind of thing that
    causes a *future* reader to assume coverage exists that doesn't — the failure mode this whole priority
    investigation was checking for.
  - Owner: `@ios-engineer`, fix alongside #1.

### 💡 Out of scope (logged, not fixed)

- Live Keychain round-trip test (AC-A2 positive half) — already disclosed by the PR as deliberately
  omitted to avoid entitlement/environment-flaky XCTest runs. Reasonable tradeoff; revisit only if a real
  Keychain-related bug shows up in the field.
- Realtime `RealtimeClientV2` wiring — correctly deferred to Stream B per spec §11; `SupabaseClients.swift`
  explicitly does not guess at its init signature.

## The author's flagged uncertainties — resolved

All three, verified against the actual pinned `supabase-swift` source (`a71f55a8d522aa38e2cecd314b64c6b24d518f8c`
== 2.55.0), fetched fresh from `raw.githubusercontent.com` for this review, not taken on the PR's word:

1. **`AuthClient(url:headers:localStorage:fetch:)` convenience initializer — EXISTS, exact signature
   confirmed.** Read `Sources/Auth/AuthClient.swift:189-229`: `public init(url: URL? = nil, headers:
   [String: String] = [:], flowType: ... = ..., redirectToURL: URL? = nil, storageKey: String? = nil,
   localStorage: any AuthLocalStorage, logger: ... = nil, fetch: @escaping FetchHandler = { try await
   URLSession.shared.data(for: $0) }, autoRefreshToken: Bool = ..., emitLocalSessionAsInitialSession: Bool
   = false)`. The PR's call site (`url:`, `headers:`, `localStorage:`, `fetch:`, letting the rest default)
   is valid. Also confirmed `AuthClient.Configuration.defaultLocalStorage` — referenced by
   `SupabaseClients.swift` as the production default — is real:
   `Sources/Auth/Storage/AuthLocalStorage.swift:38-48`, resolving to `KeychainLocalStorage()` under
   `#if !os(Linux) && !os(Windows) && !os(Android)`, i.e. true on iOS. High confidence, verified correct.
2. **`Task {}` inside `@MainActor`-isolated methods inherits `@MainActor` isolation — correct, standard
   Swift behavior, and applied correctly here.** Both `observeAuthStateChanges()` and `signInAnonymously()`
   are (implicitly, via the enclosing `@MainActor final class`) MainActor-isolated. `Task { [weak self] in
   ... }` created synchronously inside them inherits that isolation for its closure body — this is the
   well-established Swift concurrency inheritance rule, not something version- or mode-dependent in a way
   that would surprise here. The project builds under Swift 5 language mode (`SWIFT_VERSION = 5.0`,
   confirmed via `project.pbxproj`), which is if anything more permissive than Swift 6 strict concurrency
   on this exact question, not less. Low risk this differs from expectation at compile time.
3. **`SessionStorage`'s internal behavior — confirmed exactly as claimed, and the "real bug caught"
   claim independently verified as real.** Read `Sources/Auth/Internal/SessionStorage.swift:43-64`:
   `SessionStorage.live`'s `get`/`store` closures use bare `JSONDecoder()`/`JSONEncoder()` — no
   `.convertFromSnakeCase`, no custom date strategy — confirmed structurally different from
   `AuthClient.Configuration.jsonDecoder` (`Sources/Auth/Defaults.swift:18-23`, snake_case +
   custom ISO8601 date parsing, used for network responses). Also confirmed `Session` (`Sources/Auth/Types.swift:69`)
   has no custom `CodingKeys`/`init(from:)`/`encode(to:)` — fully synthesized Codable, meaning a
   hand-crafted snake_case JSON fixture written directly into test storage would silently fail to decode
   via the storage path's plain decoder (returns `nil`, logged not thrown —
   `SessionStorage.swift:55-63`'s `catch { ...; return nil }`), exactly the "passes for the wrong reason"
   failure mode the PR describes catching. The fix (seed storage via a real sign-in round-trip instead of
   a hand-crafted fixture) is sound and, per Finding #1, the one place it should have been applied a third
   time (the missing refresh-success test) wasn't — but where it *was* applied, it's applied correctly.

## Race condition assessment (`ensureSession()` fallback vs. `.signedOut` handler)

**The race is real, not hypothetical, and the `pendingSignIn` guard closes it correctly.** Traced through
`Internal/APIClient.swift:81-132`'s `handleError`: for any of the 4 `sessionCleanupErrorCodes`
(`session_not_found`, `session_expired`, `refresh_token_not_found`, `refresh_token_already_used`), it calls
`sessionManager.remove()` **and** `eventEmitter.emit(.signedOut, session: nil)` **before** returning
`.sessionMissing` as the thrown error. That means a single failed refresh (e.g. inside `ensureSession()`'s
own `try await authClient.session` call) produces *two* independent consequences: (a) the thrown
`.sessionMissing` error, caught by `ensureSession()`'s own `catch` block, which calls
`signInAnonymously()`; and (b) an asynchronously-delivered `.signedOut` event on the
`authStateChanges` stream this service is independently subscribed to (via `observeAuthStateChanges()`,
started at `init` time), whose handler *also* calls `signInAnonymously()`. Confirmed the SDK's own test for
this exact scenario, `AuthClientTests.removeSessionAndSignoutIfRefreshTokenNotFoundErrorReturned`
(`Tests/AuthTests/AuthClientTests.swift:2890-2929`), asserts both a thrown error *and* a `.signedOut` event
fire from one failed-refresh call — matching this analysis exactly.

Verified the `pendingSignIn: Task<Void, Never>?` guard actually closes this: `signInAnonymously()`'s
check-pendingSignIn / create-Task-and-assign sequence has no `await` between the check and the assignment,
so it's atomic with respect to Swift's actor-reentrancy model — the second caller (whichever of the two
call sites loses the race) will always observe the first caller's already-assigned `pendingSignIn` task and
await it rather than creating a second one, because the only suspension point (`await task.value`) occurs
strictly after the assignment. This is correctly implemented, not just plausible-looking.

One race variant I additionally checked and found to be a non-issue: on a **true first launch** (no
persisted session at all), `observeAuthStateChanges()`'s own internal `emitInitialSession` call also hits
`authClient.session`, gets `AuthError.sessionMissing`, and — because `emitLocalSessionAsInitialSession`
defaults to `false` — emits `.initialSession` with a **nil** session (not `.signedOut`). The service's
`handleAuthStateChange` switch treats a nil-session `.initialSession` as a no-op by design (comment: "the
explicit `ensureSession()` call... is what bootstraps the very first anonymous session"). So the dual-path
race is correctly scoped to "persisted-but-dead session," not "no session at all" — matches the PR's own
narrower framing of the race, not a broader one I could find evidence for.

## Scope discipline — independently verified

- `git diff --stat` (merge-base `5e33c141` → `130af57c`): exactly 6 files —
  `SupabaseAuthService.swift`, `SupabaseClients.swift` (new), `WeParkApp.swift`,
  `SupabaseAuthServiceTests.swift` (new), `Tier3AuthReactionsTests.swift`, `Tier3PinFeedbackTests.swift`.
  Confirmed stable across two separate `git diff --stat` runs in this session.
- `CommunityPinService.swift`, `ContentView.swift`, `project.pbxproj`: **zero diff** — confirmed by
  `git diff` returning empty output for all three paths.
- `CURRENT_PROJECT_VERSION = 16` at all 4 occurrences in `project.pbxproj` on this branch — confirmed via
  `grep`, matches `main`.
- `WePark` target's `packageProductDependencies`: exactly `Auth` and `Realtime` — confirmed via
  `project.pbxproj` inspection (`XCSwiftPackageProductDependency` section, lines 498-508). No `Supabase`,
  `PostgREST`, `Storage`, or `Functions` reference anywhere in the file.
- `WeParkTests` target's `packageProductDependencies`: empty `()` — confirmed, matches the PR's stated
  reason for the `#if DEBUG` Foundation-only test seam.
- `Package.resolved`: `supabase-swift` pinned to revision `a71f55a8d522aa38e2cecd314b64c6b24d518f8c` /
  version `2.55.0`, matching the PR description's stated verification source exactly.
- Migration shim: absent, and the absence is **documented**, not silent —
  `SupabaseAuthService.swift`'s header comment carries a full "why no shim" rationale, and cross-references
  `HANDOFF.md`'s "Kevin is the ONLY TestFlight user (confirmed 2026-08-13)" entry, which independently
  confirms the premise this decision rests on. This satisfies the task's requirement that the decision be
  documented, not merely absent.

## Concurrency review

- `SupabaseAuthService`: `@MainActor @Observable final class` — all state mutation (`applySession`,
  `clearSession`) happens on methods implicitly MainActor-isolated by the enclosing type; no
  cross-actor mutation path found. `authClient.authStateChanges` is `nonisolated` on the SDK's actor
  (confirmed, `AuthClient.swift:341`), so reading it from a `Task` that itself inherits MainActor isolation
  is correct — event handling hops back onto MainActor via `await self.handleAuthStateChange(...)` before
  any state write.
- `InMemoryAuthStorage: @unchecked Sendable` — `NSLock`-guarded mutable dictionary, a standard, correct
  pattern for this shape.
- `SupabaseClients: Sendable` — struct wrapping only `AuthClient` (`public actor`, therefore `Sendable`);
  auto-synthesis should hold.
- `InMemoryAuthLocalStorageAdapter: AuthLocalStorage` (private struct, `Auth` protocol requires
  `Sendable`) — only stored property is `let backing: InMemoryAuthStorage` (`@unchecked Sendable`);
  auto Sendable synthesis should hold.
- No "Modifying state during view update" risk found — no `@Observable` property is mutated synchronously
  during a SwiftUI `body` evaluation; all mutation happens inside `async` service methods.
- Project builds under Swift 5 language mode (`SWIFT_VERSION = 5.0`, confirmed via `project.pbxproj`), not
  Swift 6 strict concurrency — the actor-isolation inference this PR relies on is, if anything, less likely
  to surprise under Swift 5 mode than under Swift 6.

## What I could NOT verify (no Mac / no Swift toolchain on this VPS)

- **Actual compilation.** Nothing here substitutes for `xcodebuild build`. Every claim above is a
  source-level trace against the real pinned SDK, not a compiler run.
- **Actual test execution / pass rate.** `SupabaseAuthServiceTests.swift`'s 6 tests, and the collateral
  edits to `Tier3AuthReactionsTests.swift`/`Tier3PinFeedbackTests.swift`, are unrun. Logic traced by hand
  looks correct (see race-condition section), but XCTest's async timing behavior (the
  `testAutoResignOnSignedOut...` test's 20ms-poll-up-to-400ms wait for the `.signedOut` handler to land) is
  inherently a runtime concern, not a static one.
- **Live Keychain behavior** (AC-A2 positive half) — already flagged by the PR itself as unverified by
  design; still true here.
- **A real anonymous sign-in against prod Supabase.** All test coverage uses mocked network. The actual
  `/auth/v1/signup` request shape reaching real Supabase Auth is unverified end-to-end (though
  `insertCrowdPin`/etc.'s existing write-path tests already exercise the downstream token-usage side of
  this, unchanged by this PR).

## Most likely to fail on Kevin's compile, ranked

1. **Medium risk — the `AuthClient.FetchHandler` structural-typing boundary between `WeParkTests` and the
   `Auth` module.** `WeParkTests` deliberately never imports `Auth` (confirmed: empty
   `packageProductDependencies`), so the test seam's `fetch: @escaping @Sendable (URLRequest) async throws
   -> (Data, URLResponse)` parameter must structurally satisfy `SupabaseClients`'s
   `fetch: @escaping AuthClient.FetchHandler` when passed through, without either side ever naming the
   other's exact type. Swift's structural function-type matching should handle this (verified the two
   signatures are identical modulo an ignorable external parameter label), but this exact
   cross-module-without-shared-import pattern is new to this codebase — it's the single least-precedented
   compile boundary in the diff.
2. **Low-medium risk — default-argument closures referencing an external typealias.**
   `SupabaseClients.swift`'s designated init default (`fetch: @escaping AuthClient.FetchHandler = { try
   await URLSession.shared.data(for: $0) }`) — plausible but the least "seen this exact pattern before in
   this repo" of the changes.
3. **Low risk — `Task {}` MainActor-isolation inference.** Verified as standard behavior (see above); the
   PR itself documents the 1-line fix (`@MainActor in`) if the compiler disagrees.
4. **Very low risk — package resolution / transitive dependency graph.** Already proven by Phase 0 (PR #76,
   merged, `HANDOFF.md` confirms "the realtime track is unblocked") on Kevin's actual Mac/Xcode — this PR
   adds zero new SPM surface beyond what Phase 0 already resolved and built successfully.
5. **Very low risk — `AuthClient.Configuration.defaultLocalStorage`'s platform `#if` gate.** Trivially true
   on iOS; confirmed by reading the exact conditional.

## Smoke tests run

- `git fetch origin ios/supabase-auth-keychain-stream-a`, pinned to local ref immediately
  (`refs/qa/stream-a` → `130af57c4a29eab5a8022b4347e20715fa95b2b9`), confirmed diff-stat stable across two
  separate checks in this session (not `FETCH_HEAD`-dependent).
- `git diff --stat` against merge-base `5e33c141` — 6 files, stable.
- `git diff` (full content) read for all 6 changed files.
- `git diff` (empty-output check) for `CommunityPinService.swift`, `ContentView.swift`, `project.pbxproj`.
- `grep` sweeps: `UserDefaults`/`Calendar.current` in both new/changed production files (comments only);
  `CURRENT_PROJECT_VERSION` (16, all 4 occurrences); `packageProductDependencies`/
  `XCSwiftPackageProductDependency` sections of `project.pbxproj`.
- `gh pr view 77 --json ...` — read full PR description, cross-referenced every specific claim against
  source rather than trusting it.
- Fetched and read, at the pinned `supabase-swift` revision (`a71f55a8d522aa38e2cecd314b64c6b24d518f8c`):
  `AuthClient.swift`, `AuthClientConfiguration.swift`, `Defaults.swift`, `Internal/Constants.swift`,
  `Internal/SessionStorage.swift`, `Internal/APIClient.swift`, `Internal/SessionManager.swift`,
  `Storage/AuthLocalStorage.swift`, `AuthError.swift` (partial), `Types.swift` (partial — `Session`/`User`
  Codable shape), `Tests/AuthTests/AuthClientTests.swift` (the specific cited test).
- `HANDOFF.md` cross-reference for the "Kevin is the ONLY TestFlight user" claim (confirmed present,
  dated 2026-08-13) and for Phase 0's merge status (`#76`, `5e33c141`, confirmed merged).
- No Xcode/Swift toolchain available — build and test execution NOT performed. This is the standing,
  disclosed gate per the PR's own "Do NOT merge" instruction.

## What's working

- The three self-flagged SDK uncertainties are all correct, and were verified here against real source, not
  just re-asserted. That's a genuinely high bar for a from-scratch integration against a brand-new SDK.
- The claimed pre-ship bug catch (storage decoder vs. network decoder mismatch) is real, not a
  post-hoc rationalization — confirmed both halves (the plain-decoder storage path, and `Session`'s lack of
  custom Codable) independently.
- The `pendingSignIn` race and its fix are both real (verified via the SDK's own `handleError` behavior)
  and correctly implemented (verified via actor-reentrancy reasoning, not just "looks plausible").
- Scope discipline is excellent — every single "don't touch this" boundary from the spec (`CommunityPinService.swift`,
  `pbxproj`, `CURRENT_PROJECT_VERSION`, PostgREST) holds up under independent inspection, not just the PR's
  own say-so.
- The no-migration-shim decision is well-reasoned, documented in the code (not just the PR description),
  and consistent with the independently-verifiable `HANDOFF.md` record.
- `AuthChangeEvent`'s exhaustive `switch` (no `default:`) is a good, deliberate choice — confirmed it
  actually covers all 8 real SDK cases, so a future SDK case addition will fail to compile here rather than
  silently no-op.
