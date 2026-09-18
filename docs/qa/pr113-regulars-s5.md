# Regulars S5 (iOS models/service) QA Pass 1 — 2026-09-18

**Reviewed:** PR #113, branch `ios/regulars-s5-models` at `e4f1ec5c`, forked from `main` at `bcc86866`,
against `docs/regulars-network-spec.md` §2/§3.2–§3.6/§0 and the wire-truth migration
`supabase/07-regulars-schema.sql` (merged at `db6469e9`, PR #111).
**Verdict:** ✅ ship it (MERGE-PENDING-MAC-GATE)

## Summary

This is a clean, disciplined session. All four model types decode against `07`'s real columns
verbatim (checked field-by-field against the merged migration, not the spec's superseded SQL
sketch), every write path sends exactly the columns S1's column-level grants permit (no
`created_at`/`expires_at` leakage — the exact S1 exploit class, correctly avoided from the client
side), the date-decoding strategy is a byte-for-byte copy of `CommunityPinService`'s proven
decoder, and all six named guard tests exist with the right names. One real (if narrow) gap in
the guard-test discipline itself, and one purely mechanical merge conflict against current `main`
that whoever lands this needs to know about going in — neither blocks the Mac gate.

## Acceptance criteria checklist

- [x] `Regular.swift`: all four model types (+ `RegularInviteRedeemResult`) exist, Codable with
  manual `CodingKeys` — verified every field against `07-regulars-schema.sql`'s actual columns:
  `regular_edges` (`low_user_id`/`high_user_id`/`created_at`, no synthetic `id`), `regular_invites`
  (`id`/`created_by`/`created_at`/`expires_at`/`redeemed_by`/`redeemed_at`/`revoked_at`, all three
  redemption fields correctly optional), `pin_notes` (`pin_id`/`author_id`/`body`/`created_at`),
  `regular_notices` (`id`/`sender_id`/`body`/`scheduled_for`/`created_at`/`expires_at`,
  `scheduledFor` correctly optional). No drift found.
- [x] `redeem_regular_invite`'s four terminal states match the RPC body exactly — read the SQL
  function in `07-regulars-schema.sql` §S1-4 line-by-line: `{ok:true, regular_id}` on success,
  `{ok:false, reason:"expired_or_used"}` (not-found branch), `{ok:false, reason:"cannot_add_self"}`,
  `{ok:false, reason:"blocked"}`. `RegularsService.decodeRedeemResult` maps all four correctly and
  throws `.unrecognizedRedeemResult` on an unknown `reason` — good defensive fifth case, not a fifth
  real state.
- [x] Date decoding matches PostgREST reality — `RegularsService.makeDateDecodingJSONDecoder()` is
  character-for-character identical to `CommunityPinService.makeDateDecodingJSONDecoder()`
  (`ios/WePark/WePark/Services/CommunityPinService.swift:1207-1230`): tries
  `.withInternetDateTime + .withFractionalSeconds` first, falls back to `.withInternetDateTime`
  alone. This is the correct pair for PostgREST, which emits fractional seconds on some paths and
  not others (confirmed by diffing the two decoder bodies directly, not by inspection alone).
- [x] `RegularsService.swift`: all six methods present, correct HTTP method/path/RPC shape
  (`rest/v1/regular_edges`, `rest/v1/regular_invites`, `rest/v1/rpc/redeem_regular_invite`,
  `rest/v1/regular_notices`, `rest/v1/regular_blocks` POST+DELETE) — matches this codebase's
  established `appendingPathComponent("rest/v1/...")`/`rest/v1/rpc/...` conventions verified against
  `CommunityPinService.swift`/`ZoneMessageService.swift`'s own call sites.
- [x] Column-grant compliance — verified every write body against S1's actual grants in
  `07-regulars-schema.sql`:
  - `createInvite()` sends `{"created_by": ...}` only. Matches `grant insert (created_by) on
    public.regular_invites` (§S1-4) exactly. Test `testCreateInvite_requestBody_containsOnlyCreatedBy`
    asserts the captured wire body has exactly 1 key and explicitly asserts `created_at`/`expires_at`
    are absent — this is the actual S1 exploit S1's QA reproduced, now covered from the client side.
  - `sendNotice(...)` sends `{"sender_id", "body"}` (immediate) or `{"sender_id", "body",
    "scheduled_for"}` (scheduled) only. Matches `grant insert (sender_id, body, scheduled_for) on
    public.regular_notices` (§S1-6) exactly. Wire tests assert body key counts (2 and 3
    respectively) and explicit absence of `created_at`/`expires_at`.
  - `block(userId:)` sends `{"user_id", "blocked_user_id"}` only — matches the table's only two
    client-relevant columns; `regular_blocks` has no column-level lockdown in `07` because its two
    columns are exactly what RLS's `with check (user_id = auth.uid())` already needs.
  - No write path anywhere sends `id`, `created_at`, or `expires_at` explicitly. Verified by reading
    every `payload: [String: Any]` dictionary literal in the file, not just the wire tests' own
    assertions.
- [x] Guard tests: all six present, named exactly per spec §3.6 verbatim
  (`testRegularsEnabled_defaultsFalse`, `testRegularsSettingsRow_hidden_whenDisabled`,
  `testLeavingSoonCard_headStartRow_hidden_whenRegularsDisabled`,
  `testAppConstants_regularsHeadStartRange_matchesServerClamp`,
  `testAppConstants_regularsHeadStartDefault_is15Minutes`,
  `testRegularNoticeScheduleMode_hidden_whenRegularsDisabled`). The flag defaults `false`
  (`AppConstants.regularsEnabled = false`, `Services/Constants.swift`). Gating helpers referenced by
  the guards (`regularsSettingsRowVisible`, `regularsHeadStartRowVisible`,
  `regularNoticeScheduleModeVisible`) all exist and are pure functions matching
  `communityPhase1PinTypes(enabled:)`'s precedent shape. **See Finding #1 (🟡) — three of these six
  tests only exercise an explicit `enabled: false` override, never the function's own default
  parameter binding to the real flag; this is a real gap against this exact codebase's own
  precedent, not a hypothetical.**
- [x] Zero `Views/` files touched — confirmed via `git diff origin/main
  origin/ios/regulars-s5-models --stat`: only `Models/Regular.swift`, `Services/Constants.swift`,
  `Services/RegularsService.swift`, `WeParkTests/RegularsModelServiceTests.swift`, and two docs
  files changed.
- [x] `communityEnabled` untouched — confirmed still `true` on both sides of the diff, no line
  inside its own block was touched.
- [x] No `supabase/` changes — confirmed via diffstat.
- [x] No banned copy (avoid/ticket/fine/evasion/dodge) — grepped both new source files and the test
  file; the only matches are the standing "No Calendar.current" invariant comments, no banned words
  present anywhere.
- [x] No `Calendar.current` — confirmed, zero occurrences outside the invariant comment itself.
- [x] Test count 1373 → 1407 — re-counted independently (`grep -c "func test"` across
  `ios/WePark/WeParkTests/*.swift` on `main` = 1373; the new file adds exactly 34 `func test`
  declarations, matching the PR's own claimed inventory of 34 test names one-for-one).
- [x] Roadmap / open-items annotations present and accurate — `docs/regulars-roadmap.md`'s S5 row
  and `docs/open-items.md`'s #23 row both updated with a summary that matches the actual diff (no
  claims not backed by the code). **See Finding #2 (🟢) — the open-items.md edit will produce a
  real git merge conflict against current `main`, purely mechanical, not a content problem.**

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: Three of the six guard tests never exercise the gating functions' default parameter — they
  cannot detect a wiring bug at the exact seam the guard-test playbook exists to protect.**
  - Where: `ios/WePark/WeParkTests/RegularsModelServiceTests.swift:85-104`
    (`testRegularsSettingsRow_hidden_whenDisabled`,
    `testLeavingSoonCard_headStartRow_hidden_whenRegularsDisabled`,
    `testRegularNoticeScheduleMode_hidden_whenRegularsDisabled`), gated functions defined in
    `ios/WePark/WePark/Services/Constants.swift` (`regularsSettingsRowVisible(enabled:)`,
    `regularsHeadStartRowVisible(enabled:)`, `regularNoticeScheduleModeVisible(enabled:)`).
  - What: all three tests call their gating function with an explicit `enabled: false` argument
    (e.g. `XCTAssertFalse(AppConstants.regularsSettingsRowVisible(enabled: false))`). Since the
    implementation is a one-line passthrough (`{ enabled }`), this only proves the function doesn't
    hardcode `true` — it says nothing about whether the function's *default* parameter (the one
    every real call site actually uses: `regularsSettingsRowVisible()` with no argument) is wired to
    the real `AppConstants.regularsEnabled` flag. No test in this file calls any of the three
    functions with zero arguments. If a later session (S7/S9/S10) or a careless edit here changed
    the default to, say, `Bool = true` by mistake, none of these three "hidden when disabled" tests
    would fail — the flag would silently leak visible even with `regularsEnabled = false`.
  - Expected: this exact codebase already has the fix pattern, for the exact analogous case. See
    `ios/WePark/WeParkTests/Community2Phase1ModelTests.swift:468-474`,
    `testCommunityPhase1PinTypes_defaultParameter_matchesShippedFlag`:
    ```swift
    func testCommunityPhase1PinTypes_defaultParameter_matchesShippedFlag() {
        XCTAssertEqual(AppConstants.communityPhase1PinTypes(),
                        AppConstants.communityPhase1PinTypes(enabled: AppConstants.communityEnabled))
    }
    ```
    This PR's own file header explicitly frames `regularsEnabled` as "a direct copy of the
    [`communityEnabled`] playbook" — but the playbook's own default-parameter-binding test didn't
    come along with it.
  - Repro: add `XCTAssertFalse(AppConstants.regularsSettingsRowVisible())` (no args) to the test
    file, then temporarily change the function's default to `Bool = true` in `Constants.swift` —
    the six existing guard tests all still pass; only a new default-parameter test would catch it.
  - Owner: `@ios-engineer` (cheap fix — three one-line additions to
    `RegularsModelServiceTests.swift`, no production code change needed since the actual defaults
    are correct today; this is a test-coverage gap, not a live bug).

### 🟢 Minor / nit

- **#2: Branch is 2 commits behind `main` and will hit a real (git-confirmed) merge conflict in
  `docs/open-items.md`.**
  - Where: `docs/open-items.md`, table rows #23/#24 in the "OPEN — backend / data" section.
  - What: `main` (at `2c44c79f`) inserted a new row #24 (Brooklyn expansion, commit `f43a8aad`)
    immediately above this branch's edited row #23. Verified with an actual `git merge --no-commit`
    in a throwaway clone: `CONFLICT (content): Merge conflict in docs/open-items.md`. The conflict
    is purely mechanical (git's context-matching can't cleanly interleave two edits that land on
    adjacent lines with no separating context) — the correct resolution is trivial: keep both the
    new #24 row and this branch's extended #23 row, in that order. No content is actually in
    tension.
  - Expected: a clean merge, or at minimum a heads-up before whoever lands this hits it unprepared.
  - Repro: `git merge --no-commit --no-ff origin/ios/regulars-s5-models` on top of `origin/main` in
    a scratch clone.
  - Owner: whoever merges (rebase/resolve manually — not a code fix, no engineer action needed
    beyond a one-line conflict resolution at merge time).

### 💡 Out of scope (logged, not fixed)

- **`pin_notes`'s INSERT is not column-locked down**, unlike `regular_invites`/`regular_notices`.
  `07-regulars-schema.sql` §S1-5 has no `revoke insert ... / grant insert (author_id, body, pin_id)`
  pair the way §S1-4/§S1-6 do — a client could still explicitly set `created_at` on their own note.
  This is inherited from S1/S2 (already reviewed and passed in `docs/qa/pr111-regulars-s1-schema.md`,
  which only found the exploit live-reproducible against `regular_invites`/`regular_notices` because
  those two have rate-limit triggers keyed on `created_at`; `pin_notes` has no such trigger, so the
  practical exploit surface is materially smaller). `Regular.swift`'s own doc comment on `PinNote`
  already calls this out accurately and states `RegularsService`'s write path (deferred to S7/S9,
  not built in S5) must not rely on the column being locked down. Nothing for S5 to fix — flagging
  only so a future column-grant audit doesn't have to rediscover it.
- **Live device/two-device push and QR-scan verification (S8/S13)** — not applicable to this
  session; zero UI, zero network calls reachable from a live build (`regularsEnabled = false`).

## Smoke tests run

- **Wire-shape diff against `07-regulars-schema.sql`:** read the full 806-line merged migration and
  diffed every model's `CodingKeys` against its real column list by hand — no drift.
- **Column-grant diff:** read every `payload: [String: Any]` literal in `RegularsService.swift`
  against every `grant insert (...)`/`grant update (...)` line in the migration — no
  over-permissioned write found.
- **RPC-state diff:** read `redeem_regular_invite`'s PL/pgSQL body line-by-line against
  `decodeRedeemResult`'s switch — all four states match, defensive fifth case is sound.
- **Decoder-identity check:** diffed `RegularsService.makeDateDecodingJSONDecoder()` against
  `CommunityPinService.makeDateDecodingJSONDecoder()` — byte-identical bodies.
- **Compile-failure sweep (static, no Xcode toolchain available in this sandbox — matches the PR's
  own `[COMPILE-UNVERIFIED]` label):**
  - Brace/paren balance checked programmatically for all three new/changed Swift files — balanced.
  - Confirmed the Xcode project uses `PBXFileSystemSynchronizedRootGroup` for both `WePark` and
    `WeParkTests` (Xcode 16 auto-discovery) — new files do not need `project.pbxproj` entries;
    verified existing shipped files (e.g. `ZoneMessageService.swift`) are likewise absent from
    `project.pbxproj`, confirming this is the established mechanism, not a gap.
  - Grepped for mock-class name collisions (`RegularsAuthMockURLProtocol`,
    `RegularsWireMockURLProtocol`, and all six new test-class names) against every existing test file
    on `main` — no collisions.
  - Grepped for type-name collisions (`RegularEdge`, `RegularInvite`, `PinNote`, `RegularNotice`,
    `RegularInviteRedeemResult`, `RegularsServiceError`, `RegularsService`,
    `makeDateDecodingJSONDecoder`) against `main` — no collisions (the same-named
    `makeDateDecodingJSONDecoder` on `CommunityPinService` is a different type, no ambiguity).
  - Verified `nonisolated static func` usage against the project's
    `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting (confirmed present in
    `project.pbxproj`) — the three `nonisolated static` functions in `RegularsService.swift` are
    exactly the ones that need it (pure decoder/formatter/decode-result helpers touching no actor
    state), matching `CommunityPinService`/`ZoneStore`'s own precedent for the same reason.
  - Verified `SupabaseAuthService`'s test-only convenience initializer signature
    (`supabaseURL:supabaseAnonKey:testStorage:fetch:`) and `RegularsService`'s own initializer
    argument order against the test file's call sites — labeled-argument order matches in every
    call, and against `PushRegistrationServiceTests.swift`'s identical precedent usage.
  - Verified `appendingPathComponent("rest/v1/...")` and `"rest/v1/rpc/..."` path-building matches
    the exact string shape already used (and presumably compiling/shipping) in
    `CommunityPinService.swift`/`ZoneMessageService.swift`.
  - **Not run:** an actual `xcodebuild build`/`test` pass — no Xcode/Swift toolchain in this sandbox.
    This is the Mac gate (below), not a substitute for it.
- **Live-UI smoke:** not applicable — this PR touches zero files in the mount-chain trigger list
  (`MapViewRepresentable.swift`, `ContentView.swift`, `Views/DriveMode*.swift`,
  `.safeAreaInset`/overlay code). Confirmed via the diffstat above. No screenshot inspection
  performed or required for this PR class.
- **Merge-conflict check:** ran an actual `git merge --no-commit --no-ff` in a throwaway clone
  against current `origin/main` — found the conflict recorded as Finding #2.

## What's working

- Wire-shape fidelity is genuinely careful — every `CodingKeys` mapping was checked against the
  *merged* migration (not the spec's own, already-superseded SQL sketch), and the file headers
  explicitly call out which numbers changed between the spec sketch and the final schema (the
  `[60, 3600]` clamp, the derive-expiry anchoring) rather than silently trusting either source.
- Column-grant discipline is exactly right, including the one case (`pin_notes`) where it correctly
  chose not to over-claim a lockdown that doesn't exist yet on the server side.
- The decoder/formatter duplication-not-sharing convention, the `nonisolated static` usage, and the
  wire-level (not just payload-dict) test shape all match this codebase's established house style
  precisely — this reads like it was written by someone who actually studied
  `ZoneMessageService`/`CommunityPinService`/`PushRegistrationServiceTests` rather than
  approximating them.
- The three judgment calls flagged in the PR body (S7/S9 scope deferrals, one shared error enum,
  enum-not-thrown redeem states) are all defensible engineering calls, correctly surfaced for
  review rather than buried.
- Docs hygiene is good — `regulars-roadmap.md`/`open-items.md` updates are accurate against the
  actual diff, not aspirational.
