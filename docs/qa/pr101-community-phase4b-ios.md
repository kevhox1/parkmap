# Community 2.0 Phase 4b (iOS push + relevance router + WP5) — QA Pass 1 + Pass 2 — 2026-09-03/04

## QA Pass 2 — 2026-09-04

**Reviewed:** PR #101, branch `ios/community-phase4b` @ `46b06da6` (fetched fresh, `git show
46b06da6` verified), against `origin/main` @ `8e42a5bb` and Pass 1's findings
(`docs/qa/pr101-community-phase4b-ios.md`, below). Cold re-verification — did not trust the PR
body's or the fix commit message's own account of what changed; re-derived each claim from the
diff and, where possible, from the live schema/backend files directly.

**Verdict: MERGE-AFTER-MAC-GATE.** All five Pass 1 findings are fixed correctly, including the
out-of-scope `upsertVote` production bug the builder found and fixed unprompted. One new,
non-blocking finding from this pass (a guaranteed double-POST on every foreground event, not just
rapid cycling — wasteful, not corrupting, cheap follow-up). No code changes needed before this
goes through Kevin's Mac compile/test/live-smoke gate; the TestFlight gate ceremony is restated
in full below as the literal script to run.

### One line per item

1. **Fix #1 (on_conflict) — confirmed fixed and genuinely wire-tested.** `upsertToken`'s request
   now builds via `URLComponents` with `on_conflict=user_id,apns_token` appended and the
   `Prefer: resolution=merge-duplicates,return=minimal` header retained; the new
   `PushTokenMockURLProtocol`-based test asserts the actual intercepted `URLRequest`'s query
   string and header, not the pure payload dict. The `communityEnabledProvider` DI seam's
   production default (`{ AppConstants.communityEnabled }`) is used at exactly one production
   construction site (`ContentView.swift:856`, via the unmodified convenience init, which never
   passes an override) — grep-confirmed across the entire branch tree
   (`git grep "PushRegistrationService(" 46b06da6`) that the ONLY other construction site is the
   test file, which explicitly injects `{ true }`. The seam cannot default open in production.
2. **Fix #2 (foreground zone re-derivation) — confirmed wired**, `updatePushZoneFromParkedCarOrLocation()`
   now runs in `handleScenePhaseChange`'s `.active` branch before `handleAppForeground()`, exactly
   as the PR always claimed. **Judgment on the debounce question: `lastUploaded`-skip is
   sufficient for genuine rapid re-entrant foreground/background cycling (spaced far enough apart
   for the prior write to complete), but NOT sufficient for the specific ordering this fix
   introduced** — see new Finding #6 below. Not blocking; recommend a fast follow-up.
3. **`upsertVote` fix — confirmed real, confirmed wire-tested, confirmed zero-impact on every
   other call site.** `buildAuthenticatedRequest` gained an additive `queryItems: [URLQueryItem] =
   []` parameter; enumerated all 6 call sites in the fixed file
   (`insertCrowdPin`, `upsertVote`, `upsertProfile`, `callExtendPinExpiry`, `claim_pin` RPC,
   the block-scoped report insert) — only `upsertVote` passes a non-empty value, and the
   implementation's `if !queryItems.isEmpty { ... }` guard means every other call site's URL
   construction is byte-identical to before (skips the `URLComponents` round-trip entirely when
   empty). `testUpsertVote_requestIncludesOnConflictQueryParam` in `Tier3AuthReactionsTests.swift`
   asserts the real intercepted URL via the existing `WriteMockURLProtocol` harness. PR body
   plainly and prominently states the shipped-bug fix (its own "`upsertVote` verdict: broken, and
   fixed in this PR" section) — not buried. **This needs a `docs/field-testing-log.md` or
   open-items entry — see the dedicated ruling below.**
4. **Minors — confirmed correctly fixed, better than the minimum ask.** `.newData` is now reported
   only inside `UNUserNotificationCenter.add`'s success branch (`.noData` on the error branch);
   `dedupe.markSeen(pinId)` was moved to that same success branch, closing the "a rare `add`
   failure permanently suppresses this pin" edge case Pass 1 flagged as a side observation — the
   fix addressed more than the minimum. The WP5 foreground path's doc-comment justification for
   leaving its mark-seen timing unchanged (a synchronous `@State` assignment has no failure mode
   to defer past) is accurate and acceptable.
5. **`upsertProfile` not-affected claim — spot-verified true.** Its payload is
   `["id": userId.uuidString, "username": username, ...]` — `id` is `profiles`' actual primary
   key, so PostgREST's omitted-`on_conflict` default (`ON CONFLICT (id)`) is correct by
   construction. No `queryItems` passed, confirmed at the call site.
6. **No new issues from the seam addition itself** — the DI hook is narrowly scoped (one new
   `private let`, one new init parameter with a safe default, no change to any guard's logic,
   only the read source), and only ever overridden by tests. The one new issue this pass did find
   (the foreground double-POST) is a pre-existing interaction between `updateZone`/`handleAppForeground`
   that Fix #2's *new call site* exposed, not a defect in the seam itself.
7. **Final TestFlight gate ceremony — restated in full below**, incorporating the `APNS_ENV` step
   (now also landed in the PR body itself, confirmed) and Pass 1's checklist. This is Kevin's
   script, verbatim.

### New finding this pass

**🟡 #6 (Significant, non-blocking) — `handleScenePhaseChange`'s `.active` branch now double-POSTs
`device_push_tokens` on every single foreground event, not just rapid cycling**
- Where: `ContentView.handleScenePhaseChange` (`.active` branch) — `updatePushZoneFromParkedCarOrLocation()`
  then `pushRegistrationService.handleAppForeground()`, called back-to-back synchronously.
- What: `updatePushZoneFromParkedCarOrLocation()` calls `pushRegistrationService.updateZone(zoneId)`,
  which unconditionally calls `attemptUpsert()` — this creates a `Task` and returns immediately
  (does not await). The very next line, `handleAppForeground()`, also calls `attemptUpsert()`
  synchronously, before the first `Task` has had any chance to complete a network round-trip and
  update `lastUploaded`. Since both calls build the identical `UploadKey` candidate (same token,
  same environment, same freshly-resolved zone in the common case), `attemptUpsert`'s only guard
  (`candidate != lastUploaded`) passes both times — two `Task`s are created, two POSTs fire, and
  the second overwrites `inFlightUpload`'s reference to the first (the first still runs to
  completion in the background; nothing is lost or corrupted, just duplicated).
- Verified this is not a rare "rapid cycling" edge case — it is the **default** behavior on every
  ordinary single foreground transition after this PR's Fix #2, because `updateZone()`'s own
  `attemptUpsert()` call and `handleAppForeground()`'s `attemptUpsert()` call are now always
  adjacent in the same synchronous call chain.
- Impact: wasteful (2x network calls + 2x Edge-adjacent PostgREST writes per foreground), but not
  corrupting — thanks to Fix #1, the upsert is now a genuine idempotent upsert on the real
  constraint, so both requests converge on the same final row state. No privacy impact (same data
  both times), no correctness break of any acceptance criterion. `device_push_tokens` itself has
  no trigger (confirmed — only `pins` INSERT triggers `send-community-push`), so there's no
  server-side amplification beyond the doubled write itself.
- Recommend (either, follow-up, not blocking): (a) drop the now-largely-redundant
  `handleAppForeground()` call from the foreground branch now that
  `updatePushZoneFromParkedCarOrLocation()` already re-attempts the upload with fresher data, or
  (b) add an in-flight-candidate guard to `attemptUpsert()` (skip if `inFlightUpload` is
  non-nil/still running for an equal candidate) so overlapping calls coalesce instead of both
  firing.
- Owner: `@ios-engineer`, follow-up ticket, not a merge blocker.

### `upsertVote` production-defect ruling — where it belongs in this repo's record-keeping

This was a live, shipped, flag-off-reachable production bug (any user tapping "Still there?" then
later "Gone" — or vice versa — on the same `enforcement_active`/`sweeper_passed` pin, i.e. every
normal use of Tier 3's reaction UI, would 23505 on the second vote instead of updating it) that
this PR's builder found as a side effect of QA's out-of-scope flag and fixed in the same commit.
**Recommend logging it, distinct from the routine PR-fix narrative**, because "an already-shipped,
flag-independent user-facing action has been silently erroring in production" is exactly the class
of incident this repo's existing logs (`docs/field-testing-log.md`, the S11 "ceremony incident"
entries in the roadmap) are for — not because the fix itself needs more process, but so a future
agent auditing "has confirm/dispute voting ever been broken in prod" has a citable answer instead
of re-deriving it. **Concretely: one line in `docs/field-testing-log.md`** (that file's existing
convention for "here's a real behavior gap found live," e.g. the FT-1 TTL entry this same spec
references) stating: date, "`upsertVote`'s missing `on_conflict` meant a SECOND vote (confirm→dispute
or vice versa) on the same pin/user pair silently failed with a 23505 in production since Tier 3
sub-PR #1 shipped; found by PR #101 QA pass 1's out-of-scope flag, fixed same-commit `46b06da6`."
Do not also open a separate `docs/open-items`-style ticket — the fix already landed, there is
nothing left to track/schedule, only to have on the record. If Kevin wants a live-data sanity
check (how many "Gone"-after-"Still there?" attempts silently 23505'd before this fix), that would
require a Supabase log/error query, which is his call, not something to gate this PR on.

### Smoke tests run (Pass 2)

- Fetched `origin` fresh and diffed `ef3efe11..46b06da6` directly (`git diff`, `git show`) rather
  than trusting the fix commit message's or PR body's account — every claim above traces to a
  specific diff hunk or line I read this pass.
- Re-read `PushRegistrationService.swift`'s changed regions in full, including the new
  `communityEnabledProvider` property, its doc comment, and both call sites (production +
  test) — grep-verified no third construction site exists anywhere in the branch tree.
- Re-read the new `testUpsertToken_requestIncludesOnConflictAndMergeDuplicatesPreferHeader` and
  `testAttemptUpsert_sameCandidateTwice_secondCallSkipsNetwork` tests in full — confirmed both are
  genuine wire-level assertions against an intercepted `URLRequest`, not payload-shape checks.
- Enumerated every `buildAuthenticatedRequest` call site in the fixed `CommunityPinService.swift`
  by reading each one directly (not just grepping the count) — `insertCrowdPin` (×2, including the
  block-scoped report path), `upsertVote`, `upsertProfile`, `callExtendPinExpiry`, `claim_pin`
  RPC — confirmed only `upsertVote` supplies `queryItems`.
- Re-read `testUpsertVote_requestIncludesOnConflictQueryParam` in full — genuine wire assertion,
  reuses the existing `WriteMockURLProtocol` harness correctly.
- Re-read the `WeParkApp.swift` diff for Finding #4/#5's fix — confirmed `.newData`/mark-seen both
  moved into the `add(request:)` success closure correctly, `.noData` on the error branch.
- Independently recounted test functions: `PushRegistrationServiceTests.swift` = 28 (`grep -c
  "    func test"`, was 26 + the two new wire tests); `Tier3AuthReactionsTests.swift` = 11 (was 10
  + the one new wire test) — matches the commit message's claimed "29 new/changed tests total"
  and the coordinator's static count (1154 + 29 = 1183).
- Read the live PR #101 body (`gh pr view 101 --json body`) directly, not a paraphrase — confirmed
  the QA-fixes section, the "`upsertVote` verdict" section, and the fully expanded TestFlight
  procedure (including the `APNS_ENV` step) are all actually present, not just claimed in the fix
  commit message.
- Re-checked `device_push_tokens` for any table-level trigger that could amplify the new Finding
  #6's double-write — confirmed none exists (only `pins` INSERT triggers `send-community-push`).
- **Not performed, same as Pass 1, for the same reason:** live Xcode build/test/simulator smoke
  (`ContentView.swift`'s `mapZStack` mount-chain) and a live curl-based confirmation of the
  `on_conflict` fix against the actual deployed Supabase project — this environment has no
  Xcode/Supabase-credentialed toolchain. Both are folded into the gate ceremony below as mandatory
  pre-TestFlight steps, not skipped silently.

---

## Final TestFlight gate ceremony (Kevin's script, verbatim)

Supersedes Pass 1's version — this is the ceremony to actually run, incorporating the `APNS_ENV`
step and everything both passes verified.

**0. Prerequisite (done as of `46b06da6`):** Pass 1's blocking finding and all significant/minor
findings are fixed and re-verified in Pass 2. No further code changes required before proceeding.

**1. Mac-side compile/test gate, flag off (the merged state):**
   - `xcodebuild build` for the `WePark` scheme.
   - `xcodebuild test -scheme WePark` with `communityEnabled` still `false` — expect the full
     suite green (1183 total per the static count: 1154 baseline + 29 from this PR).

**2. Pre-archive checklist, immediately before the flag-on TestFlight build:**
   - `git status` on `main` — confirm clean, up to date with `origin/main`.
   - Bump the build number via Xcode's normal mechanism and **commit that bump to `main` on its
     own, ordinary commit** — keeps the shipped build number traceable to a real commit even
     though the flag flip itself won't be.
   - Locally edit `ios/WePark/WePark/Services/Constants.swift`: `communityEnabled = false` →
     `true`.
   - `git diff` — confirm the *only* uncommitted change is that single line (closes the "other
     uncommitted work rides along" risk named in Pass 1).
   - **Flip the `send-community-push` Edge Function's `APNS_ENV` secret to `production`**
     (`supabase secrets set APNS_ENV=production --project-ref jiispshyqerscdoferaw`, or the
     Supabase Dashboard — Kevin's own action per the standing "Kevin applies Supabase config
     himself" convention). **Required, not optional:** `send-community-push` filters
     `device_push_tokens` by `.eq("environment", apnsEnv)` and defaults to `'sandbox'` if unset;
     TestFlight-provisioned tokens stamp `environment = 'production'`. Skipping this step means
     zero pushes send, with no error anywhere — the exact "compiles, runs, never receives push,
     no error" trap class this spec has been burned by before.

**3. Local test run with the flag flipped true (belt-and-suspenders — Archive itself does not run
   tests):**
   - `xcodebuild test -scheme WePark` with `communityEnabled = true`.
   - Expect **exactly 3 known pre-existing failures** per the roadmap's 2026-08-28 note. None of
     this PR's 29 tests reference `AppConstants.communityEnabled` directly (the new
     `communityEnabledProvider` seam is injected explicitly in tests, never left to read the real
     flag) — verified this pass, so none of the 29 should be among those 3. If the count differs,
     or a failure is in a file this PR touched, stop and investigate before archiving.

**4. Live-UI smoke with the flag on (mandatory — not performed by either QA pass, no Xcode/simulator
   toolchain in this environment; this PR touches `ContentView.swift`'s `mapZStack`, the
   mount-chain class this repo's QA discipline treats as merge-blocking without a live screenshot):**
   - Build + install on Kevin's physical device (required regardless, for step 6 — push cannot be
     verified in Simulator).
   - Screenshot the map with the flag on. Confirm existing chrome (toolbar, ASP banner, Park Until
     pill, polylines) still renders unchanged.
   - If reachable, trigger a `sweeper_passed` pin matching the parked car's segment and confirm
     the `ConfirmPromptCard` renders correctly above the sheet and both buttons work.

**5. Archive** (`Product > Archive` in Xcode) — confirmed does not run tests, safe regardless of
   step 3's outcome.

**6. Upload to TestFlight.**

**7. Immediately after the archive completes:**
   - `git diff` once more, reconfirm nothing else crept in.
   - `git checkout -- ios/WePark/WePark/Services/Constants.swift` — discard the local flag flip.
   - `git status` — confirm clean.
   - **Before the next unrelated commit of any kind, re-run `git diff -- ios/WePark/WePark/Services/Constants.swift`
     as a habit** until this feature fully launches — the cheapest guard against the flag shipping
     enabled to `main` by accident on a routine commit (the asymmetric risk named in Pass 1: this
     is gated on the not-yet-complete build-18 drive test).

**8. Record a one-line breadcrumb** (HANDOFF.md or the roadmap doc): "TestFlight build `<N>`
   archived from `main@<sha>` with `communityEnabled` locally flipped true (Option B),
   `APNS_ENV=production`, discarded after archive."

**9. On-device AC-P4.3 verification** (roadmap S12 row: "Physical phone + SQL insert verifies
   AC-P4.3 — works outside NYC"): SQL-insert an `enforcement_active`/`sweeper_passed` pin matching
   the phone's parked segment — confirm a local, user-visible notification fires. Insert a second
   pin in the *same zone* but a *different* segment — confirm silence (push received per Edge
   Function logs, nothing surfaced to the user). This is the literal proof the relevance gate
   works without the server ever learning the device's parked location.

**10. Optional but recommended, non-blocking:** file the Finding #6 follow-up (foreground
   double-POST) as a fast fix before or shortly after this TestFlight cycle — cheap, not required
   to gate on.

**11. Only after AC-P4.3 + the WP5 card are verified live, and separately after the build-18 drive
   test passes** (roadmap's own sequencing: the drive-test gate applies to the flag-flip for
   *external* testers, not to any merge or to Kevin's own internal TestFlight install) — expand
   beyond Kevin's own device to external testers.

---

# Pass 1 (original, 2026-09-03) — kept for history

**Reviewed:** PR #101, branch `ios/community-phase4b` @ `ef3efe11`, against `origin/main` @ `8e42a5bb`,
per `docs/community-2.0-reconciliation-spec.md` §2.9 (as amended, PR #100) + §3 Phase 4 +
`docs/community-2.0-roadmap.md` S12 row + the live backend (`supabase/functions/send-community-push/index.ts`,
`supabase/03-community-2.0-schema.sql`).

**Verdict: FIX-THEN-MERGE.** One well-evidenced blocking bug in the token-upsert request (defeats
an explicit acceptance criterion silently, cheap to fix). Everything else — the privacy gate,
environment stamping, the shared relevance predicate, completion-handler discipline, copy
verbatim, and the WP5 presentation judgment call — reads correct on a cold, adversarial read. Full
TestFlight gate ceremony below; this is the "Kevin's Mac gate" writeup requested. **(Superseded by
Pass 2 above — all findings here are fixed as of `46b06da6`.)**

## Summary

The core architecture is sound and the privacy invariant (server never learns a parked blockface)
holds: `ParkedCarSegmentReader` duplicates `ParkPinService`'s exact storage key/envelope shape
correctly, the comparison is 100% on-device, and the only thing ever uploaded is `(user_id,
apns_token, environment, zone_id)` — verified against the token-payload unit test and the live
Edge Function's actual read query. `CommunityPushRelevance` is genuinely one shared pure function
wired into both the background `AppDelegate` path and the foreground
`ContentView.updateConfirmPromptCandidate` path (grep-confirmed, not just claimed), with correct
`.noData`/`.newData` completion-handler discipline. The WP5 card's "floating overlay, not modal
sheet" judgment call is the right read of the prototype (verified verbatim against
`prototype.html:104-113`, which is itself an absolutely-positioned floating card above the sheet,
not a modal). The 26 tests are real, behavior-asserting, and independently counted (26 `func test`
matches the file's own inventory).

The one blocking finding: `PushRegistrationService.upsertToken`'s POST to `device_push_tokens`
never supplies an `on_conflict` query parameter, but the table's primary key (`id`,
server-generated, never present in the payload) is *not* the constraint the upsert is supposed to
target — the schema's actual `unique (user_id, apns_token)` constraint is. Per PostgREST's
documented default (missing `on_conflict` → conflict target defaults to the primary key) —
independently corroborated by this repo's own `ingest-film-permits/index.ts`, whose comment
explicitly documents needing `on_conflict` for exactly this reason — the very first token
registration will succeed, but every subsequent upsert for the same device (zone change, app
foreground, relaunch) will hit a real Postgres unique-constraint violation on `(user_id,
apns_token)` that `ON CONFLICT (id)` does not catch, and fail. The failure is swallowed silently
(`catch { /* best-effort */ }`), so "re-upsert on zone change" — an explicit acceptance criterion
in both the spec and this PR's own description — silently never works again after a device's
first-ever registration. This does not break the privacy boundary itself (segment/location is
never uploaded either way), but it does mean a device's `zone_id` on the server gets stuck at
whatever it was on first registration, which defeats the entire point of zone-scoped push
targeting for any user who parks in a second zone.

## Acceptance criteria checklist (from the PR description)

- [x] Flag-gated end-to-end — verified by reading every call site: `requestRegistrationIfEnabled`,
      `didReceiveDeviceToken`, `updateZone`, `handleAppForeground` all internally guard on
      `AppConstants.communityEnabled`; `AppDelegate.didReceiveRemoteNotification` guards first thing;
      `confirmPromptOverlay` and `updateConfirmPromptCandidate`'s call site both guard on the flag too.
      Flag is `false` on this branch (`Constants.swift:154`) — genuine no-op confirmed by code reading.
- [x] Environment stamping mechanism + documented failure mode — verified `parse(profileString:)`
      against all four branches (dev/prod/nil/malformed), all fall back to `.production` except an
      actual `development` value; matches the three real-world cases correctly.
- [ ] Token upsert keyed on `(user_id, apns_token, environment, zone_id)`; **re-upsert on zone
      change/foreground — FAILS after the first successful write.** See Finding #1 (Blocking).
      **[Pass 2: fixed, see above.]**
- [x] Silent-push handler: parses payload correctly (matches the live `send-community-push` payload
      shape exactly — `pin_type`/`segment_id`/`pin_id`/`zone_id`, no author/no lat-lng), compares
      on-device only, correct `.noData`/`.newData` discipline at every branch.
- [x] WP5 confirm-prompt card: copy verified verbatim against `prototype.html:104-113` (only the live
      `confirmCount` substitutes for the mockup's static "148", as intended); shared predicate with the
      push path (grep-confirmed one function, two call sites); cross-path dedupe via
      `CommunityPushDedupeStore`, backed by UserDefaults, tests cover mark/trim/malformed-entry-skip.
- [x] Tests added for all five listed areas, count independently verified: 26 `func test` in the file,
      matching the header's own inventory line-for-line. **[Pass 2: now 29 total, verified.]**

## Findings

### 🔴 Blocking

- **#1: `device_push_tokens` token upsert doesn't target the table's actual unique constraint —
  every upsert after the first for a given device silently fails** — **[Pass 2: FIXED, verified.]**
  - Where: `ios/WePark/WePark/Services/PushRegistrationService.swift:557-572` (`upsertToken`)
  - What: The POST to `rest/v1/device_push_tokens` sets `Prefer: resolution=merge-duplicates,
    return=minimal` but the request URL carries no `on_conflict` query parameter, and the JSON body
    (`tokenUpsertPayload`) never includes `id`. `device_push_tokens.id` is `uuid primary key default
    gen_random_uuid()` (`supabase/03-community-2.0-schema.sql:535`) and the real dedupe target is a
    *separate* constraint, `unique (user_id, apns_token)` (line 542). Per PostgREST's documented
    default — when `on_conflict` is omitted, the generated SQL is `INSERT ... ON CONFLICT (<primary
    key columns>) DO UPDATE` — this compiles to `ON CONFLICT (id) DO UPDATE`. Since `id` is
    server-generated fresh on every INSERT attempt (never supplied by the client, never actually in
    conflict), that ON CONFLICT clause never fires, and the underlying INSERT instead hits the
    `unique (user_id, apns_token)` constraint as an ordinary, un-caught `23505` unique-violation error
    (Postgres only suppresses a conflict on the *exact* constraint named in `ON CONFLICT`, not a
    different one that happens to also be violated).
  - Independent corroboration in this exact repo: `supabase/functions/ingest-film-permits/index.ts:507-518`'s
    own comment explicitly documents this exact PostgREST behavior — a previous session on this
    codebase already had to reason through the identical conflict-target-must-be-explicit gap for a
    different table.
  - Effect: first-ever registration for a device succeeds (nothing to conflict with yet). Any
    subsequent call — zone change, app foreground, or a relaunch that resolves to the same token but a
    different zone — calls `attemptUpsert()` → `upsertToken` → gets a non-2xx response → the `catch`
    block on line 580 silently swallows it → `lastUploaded` is never updated → the server's copy of
    `zone_id` is permanently stuck at whatever the device's very first registration resolved to.
  - Fix: append `on_conflict=user_id,apns_token` to the request URL in `upsertToken`, and add a
    `PinMockURLProtocol`-style test asserting the outgoing request URL contains it. Owner:
    `@ios-engineer`. **Done — see Pass 2.**

### 🟡 Significant

- **#2: Zone re-derivation is not actually wired to app-foreground, despite being claimed** —
  **[Pass 2: FIXED, verified.]**
- **#3: TestFlight gate procedure doesn't cross-reference the required server-side `APNS_ENV`
  secret flip** — **[Pass 2: FIXED — the PR body's procedure section now includes it.]**

### 🟢 Minor / nit

- **#4:** `.newData` reported unconditionally regardless of `add`'s success. **[Pass 2: FIXED.]**
- **#5:** Dedupe marks "seen" before confirming the surface actually succeeded. **[Pass 2: FIXED
  for the background path; the foreground path's unchanged timing is justified in a doc comment,
  judged acceptable.]**

### 💡 Out of scope (logged, not fixed) — now resolved

- `CommunityPinService.upsertVote` had the same missing-`on_conflict` shape against `votes`'
  `unique(pin_id, user_id)` constraint. **This was a real, live, flag-off-reachable production
  bug**, not just a theoretical risk — confirmed and fixed in `46b06da6`. See Pass 2's dedicated
  ruling on where this belongs in the repo's record-keeping.

*(Remainder of the original Pass 1 body — privacy-gate trace, environment-stamping analysis,
registration-flow trace, relevance-predicate/copy verification, WP5 presentation ruling, and
test-coverage review — is superseded by Pass 2's re-verification above and omitted here to avoid
duplicate maintenance; see git history of this file for the full original text if needed.)*
