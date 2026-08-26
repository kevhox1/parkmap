# FT-2: Delete Own Community Pin — QA Pass 1 — 2026-08-24

**Reviewed:** branch `ios/ft2-delete-own-pin` at `2b8b17e7`, against `docs/ft2-delete-own-pin-spec.md`
**Environment:** Linux VPS. No Xcode, no simulator, no `xcodebuild`. This review is 100% static
(read the diff, traced execution paths by hand). No test run, no build, no live smoke performed
by me — Kevin's on-device results (below) and his `xcodebuild test` run are relied on for anything
requiring a compiler or a device.
**Verdict:** 🟡 **MERGE WITH FOLLOW-UP**

## Summary

The ownership predicate (`isOwnPin`, `PinDetailSheet.swift:535`) is unchanged from the pre-existing
A1 guard and is correct for every case traced, including nil `author_id`, a stale/rotated anon
identity, and Realtime-delivered pins (author_id is a base-table column, present in Realtime WAL
payloads — only `author_username`, a view-only join, is absent). **The delete affordance cannot
render on a pin the user doesn't own; RLS is a real backstop, not just belt-and-suspenders** — but
one of the two feared inputs to that backstop (an HTTP 403 that the client actually branches on) is
very likely never delivered by Postgres/PostgREST for a plain RLS-filtered `DELETE`, only for the
`UI guard is broken` case, which is not otherwise reachable. That's a real gap between what
AC-FT2.11 expects and how PostgREST behaves — not a security hole, but worth a spec correction
before Kevin runs that AC's curl check. The `pendingOptimisticDeletes` rollback/echo-suppression
logic is correct for the single-caller case in every ordering I traced (rollback-then-late-echo
self-corrects via `removePin`'s unconditional removal, echo-during-round-trip correctly suppresses
rollback, 404-as-success never rolls back). It has one real latent bug for the case of two
concurrent `deleteCrowdPin` calls on the *same* id: the second call's `defer` unconditionally clears
the shared dictionary entry even when that call never set it, which can wipe out the first call's
in-flight bookkeeping. This is not reachable through the shipped UI today (the button is replaced by
a spinner before any second tap could register), so it does not block merge, but it's a real
correctness gap worth a fast follow-up rather than "no known issue." No migration is needed and none
was added — correct, per spec and per the already-live schema.

## Acceptance criteria checklist

- [x] AC-FT2.1 — Backend RLS verify. **Not independently verifiable from this sandbox** (no prod
      access). `pins_delete_own` and the `votes` cascade FK are present in the committed
      `supabase/02-pins-schema.sql:156-159` and `:166` respectively, and no new migration is needed
      *if* that file is what's live in prod. This is Kevin's manual gate per spec §3.1 — confirm he
      ran the two verification queries before merging to a branch that touches prod.
- [x] AC-FT2.2 — Delete button visible only on own pins — verified by trace (`isOwnPin` routes
      `ReactionsRow.body` to `deleteSection`).
- [x] AC-FT2.3 — Delete button not visible on others' pins, including `author_id = null` — verified
      by trace; matches FT-3's field-log finding that null-author pins already exercise the
      non-own vote path.
- [x] AC-FT2.4 — Confirmation dialog fires on tap — verified by reading `.confirmationDialog` block,
      title/message/button roles match spec exactly (`PinDetailSheet.swift:434-444`).
- [x] AC-FT2.5 — Cancel does nothing — `Button("Cancel", role: .cancel) {}`, no state mutation, sheet
      stays open by construction (SwiftUI dismisses only the dialog on cancel).
- [x] AC-FT2.6 — Confirm triggers optimistic removal — `deleteCrowdPin`'s `visiblePins.removeAll`
      happens synchronously before the network `await` (`CommunityPinService.swift:1482`), and test
      `testDeleteCrowdPin_optimisticRemoval_beforeNetworkCall` proves it.
- [x] AC-FT2.7 — Sheet dismisses on success — `handleDelete()` calls `onDismiss()` immediately after
      `deleteCrowdPin` returns without throwing (`PinDetailSheet.swift:614-628`).
- [x] AC-FT2.8 — Toast fires after dismiss — same call site, `ToastService.shared.show(...)` runs
      after `onDismiss()`.
- [x] AC-FT2.9 — Network failure shows error, keeps sheet open, pin restored — verified by trace and
      by 4 dedicated rollback tests (7, 7a, 7b, 7c below).
- [x] AC-FT2.10 — Double-tap protection — verified by trace: `deleteSection`'s `@ViewBuilder` swaps
      the button for a bare `ProgressView` once `isLoading` is true, removing the tappable target
      entirely, not just disabling it. See Finding #2 for a narrow theoretical gap in this guard's
      timing margin (not blocking).
- [ ] AC-FT2.11 — RLS server-side enforcement returns HTTP 403. **Disputed — see Finding #1.**
      RLS-filtered `DELETE`s in PostgREST typically return a 2xx/204 with zero rows affected, not
      403, when no trigger explicitly raises `insufficient_privilege`. `pins_delete_own` is a bare
      `USING` policy with no such trigger. The code's 403-handling branch is real and tested, but is
      likely unreachable via the mechanism AC-FT2.11 describes. Not a security failure — RLS still
      prevents the row from being deleted — but the AC as worded will likely fail a literal curl
      test. Flagging as a spec-language issue for Kevin to correct or re-verify, not a code defect.
- [x] AC-FT2.12 — No vote buttons shown on own pin — verified; `voteSection` is only reached in the
      `else` branch of `if isOwnPin`.
- [ ] AC-FT2.13 — Live smoke gate. **Kevin's manual step, partially done.** Own-pin delete confirmed
      on-device (build/steps a–d). Step (e) — "tap someone else's pin → no delete button" — is
      **explicitly untested on device** (no other users' pins were available). See "What only a
      device can settle" below.
- [x] AC-FT2.14 — Votes cascade on server. Not independently re-verified against live data (no prod
      access), but the FK definition (`on delete cascade`) is unchanged and pre-existing; nothing in
      this PR touches it.
- [x] AC-FT2.15 — Existing tests still pass — Kevin reports 842/0 vs. an 830 baseline (830 + 12 new
      = 842, consistent with the test file's own math). Not independently re-run by me (no
      toolchain in this sandbox).

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: AC-FT2.11's expected HTTP 403 from an RLS-rejected `DELETE` is very likely wrong; the
  client's 403-handling branch is probably unreachable for the scenario it's written for.**
  - Where: `CommunityPinService.swift:1512-1516` (the `403 → CommunityPinWriteError.httpError`
    branch), and spec `docs/ft2-delete-own-pin-spec.md` §4.1 step 4 / AC-FT2.11.
  - What: For a plain RLS `USING` policy on `DELETE` (no explicit `RAISE EXCEPTION` trigger backing
    it — `pins_delete_own` has none), Postgres/PostgREST treats a row excluded by the policy as
    simply not matched by the `DELETE ... WHERE id = eq.<uuid>` — the request succeeds with **zero
    rows affected**, returning 200 (with `Prefer: return=representation`) or 204 (with
    `Prefer: return=minimal`, which is what this PR sends). It does **not** return 403. This
    codebase's own existing 403 handling elsewhere (`CommunityPinService.swift:1827-1837`,
    `enforce_block_scoped_rate_limit()`) is for a case where a **trigger explicitly raises**
    `insufficient_privilege` (SQLSTATE `42501`) — a different mechanism from a bare RLS `USING`
    filter. `pins_delete_own` has no such trigger.
  - Expected (per spec/AC-FT2.11): "A direct curl DELETE against `rest/v1/pins?id=eq.<pinId>` with a
    JWT that does not match `author_id` returns HTTP 403."
  - Impact: **Not a security bug** — the row is genuinely never deleted either way, so no
    unauthorized data loss occurs regardless of which status code comes back. The impact is
    entirely in what the *client* does with the response: if the UI guard were ever broken and the
    delete affordance appeared on someone else's pin, the client would very likely receive 204
    (success), which `deleteCrowdPin` treats as an unconditional success — it would call
    `onDismiss()` and show "Report deleted." even though nothing was actually deleted server-side.
    The optimistic removal is never rolled back on this path (rollback only fires on thrown
    errors), so the user gets a false "success," and the pin silently reappears on the next 8s poll
    with no explanation. Today this is theoretical because the UI guard is correct (see
    Acceptance Criteria above) — but it means the "403 is the authoritative backstop" framing in the
    spec's Edge Cases section (§5, "User taps delete on another user's pin") describes a response
    the server is unlikely to actually send.
  - Repro: cannot be reproduced from this sandbox (no prod access). Recommend Kevin run the literal
    AC-FT2.11 curl test against a real pin authored by a different (test) identity and record the
    actual status code and whether the row still exists afterward, rather than assuming 403.
  - Owner: `@backend-data` (spec correction / RLS behavior confirmation) with `@ios-engineer`
    informed (the 403 branch and its test, `testDeleteCrowdPin_403_throwsHttpError`, remain
    harmless dead weight if this is confirmed, not a bug to fix — but AC-FT2.11's wording and the
    "not obviously reachable in normal use → false positive" edge case are real docs/robustness
    gaps worth closing).

- **#2: `pendingOptimisticDeletes[id]` can be wiped by a second, unrelated `deleteCrowdPin` call for
  the same id, because the `defer` that clears it is unconditional.**
  - Where: `CommunityPinService.swift:1476-1479` (`if capturedPin != nil { pendingOptimisticDeletes[id]
    = false }` — conditional set — immediately followed by an *unconditional* `defer {
    pendingOptimisticDeletes[id] = nil }`), interacting with `rollbackOptimisticDelete` at
    `CommunityPinService.swift:1539-1545`.
  - What: Trace two concurrent `deleteCrowdPin(id: X)` calls (call A first, call B second, same id).
    Call A captures the pin, sets `pendingOptimisticDeletes[X] = false`, removes it from
    `visiblePins`, and awaits its network response. Call B then runs: `visiblePins.firstIndex`
    returns `nil` (A already removed it), so `capturedPin == nil`, so B's `if capturedPin != nil`
    guard is false and B does **not** set the dictionary entry — but B's `defer` still registers
    (the defer statement is not inside that `if`) and, when B's own call returns/throws, B's defer
    unconditionally executes `pendingOptimisticDeletes[X] = nil` — clearing the entry **A** is
    still relying on, regardless of whether A's request has resolved yet. If A's request
    subsequently fails (e.g., the DELETE actually succeeded server-side, and Realtime flipped A's
    entry to `true`, but B's defer already reset it to `nil` in the interim), `rollbackOptimisticDelete`'s
    `guard pendingOptimisticDeletes[id] != true else { return }` sees `nil` (not `true`) and
    proceeds to resurrect the pin — exactly the "map disagrees with server truth" bug FT-2 exists
    to prevent, reintroduced via the cross-call interference the doc comment ("An id is only ever
    present here for the duration of one `deleteCrowdPin` call") assumes but does not enforce.
  - Expected: the in-flight bookkeeping for one call should not be clearable by an unrelated call for
    the same id; each call should only clear/consult an entry it itself owns (e.g., only clear if
    `capturedPin != nil`, or use a call-scoped token instead of a bare `Bool`).
  - Repro: not reachable through the shipped UI today — `deleteSection`'s `@ViewBuilder` swaps the
    tappable button for a `ProgressView` as soon as `isLoading` flips true, and the
    `.confirmationDialog`'s destructive button can only be tapped once per presentation (the system
    dismisses the dialog on any tap). This would require a future caller (e.g., a second entry point
    to `deleteCrowdPin` for the same id, or a scheduling anomaly where two `Task {}` closures for the
    same button race before the first sets `isLoading`) to trigger. Flagging as a real, if currently
    dormant, logic bug rather than a "does not apply" — the task explicitly asked whether the map can
    misbehave under concurrent deletes of the same pin, and it can.
  - Owner: `@ios-engineer`. Suggested fix direction: only register the `defer` when `capturedPin !=
    nil` (i.e., move the `defer` inside the same `if` that sets the entry), or use a strictly
    call-scoped mechanism (e.g. compare-and-clear only if the value hasn't been touched by another
    call) instead of a bare `[UUID: Bool]`.

### 🟢 Minor / nit

- **#3: Test file header count is internally inconsistent.** `FT2DeleteOwnPinTests.swift:14` says
  "Test inventory (13 tests..." but 12 `func test...` methods exist in the file (verified via
  `grep -c`), and the header's own itemized list (1, 2, 3, 4, 5, 6, 7, 7a, 7b, 7c, 7d, 8) sums to 12.
  The file's *baseline math* at line 64-65 ("830 + 8 = 838", "838 + 4 = 842") is correct and matches
  Kevin's reported 842/0. Just the "13" on line 14 is off by one. Cosmetic.
- **#4: `isStillHereDisabled` and `isGoneDisabled` retain the `isOwnPin` check as "dead code... kept
  as a defensive second guard"** (`PinDetailSheet.swift:543`, `:606-607`). This is genuinely
  unreachable now that `voteSection` is only rendered in the non-own branch, but it's a harmless,
  clearly-commented belt-and-suspenders check, not a real problem. No action needed.

### 💡 Out of scope (logged, not fixed)

- The response-body/`Content-Range` header PostgREST returns on a zero-rows-affected `DELETE` is not
  inspected by this code (only the status code is). If Finding #1 is confirmed, a future hardening
  pass could check for zero-rows-affected explicitly (via `Prefer: return=representation` +
  inspecting the returned array length, or the `Content-Range` header) to distinguish "genuinely
  deleted" from "RLS silently no-op'd" rather than trusting the status code alone. Not needed for
  this PR given the UI guard is correct and this is a defense-in-depth improvement, not a fix for an
  observed bug.
- Undo, admin delete, durable-pin deletion semantics, Realtime SDK's `mergeRealtimeDeletion(pinId:)`
  for *other* users' deletes — all explicitly out of scope per spec §2/§9 and not present in this
  diff. Correctly excluded.

## What only a device (or a second user's pin) can settle

- **AC-FT2.13(e) — "tap someone else's pin → no delete button visible, vote buttons present."**
  This is the one AC with zero device evidence, exactly as flagged going in. I traced the
  ownership predicate by reading (see checklist above) and found it correct for every case I could
  construct on paper — nil `author_id`, a stale/rotated anon identity, and Realtime-delivered pins
  (author_id survives the base-table/view distinction; only `author_username` doesn't). But reading
  code is not the same as watching the UI render against a real second-author pin. Recommend Kevin
  or QA get a second identity's pin on the map (a fresh simulator/second device signing in
  anonymously and dropping a pin, or a seeded open-data pin with `author_id = null` as a
  lower-fidelity substitute since FT-3's field log confirms that path already exercises the
  non-own vote UI) and confirm visually before calling AC-FT2.13 fully closed.
- **AC-FT2.11's actual status code.** Whether a non-owner's `DELETE` against `rest/v1/pins` returns
  403 or 204-with-zero-rows-affected can only be settled with a real curl against prod (or a local
  Supabase instance with the same schema) using two distinct authenticated identities. See Finding
  #1.
- **AC-FT2.14, votes cascade.** Requires a live pin with at least one vote, deleted, then a
  `select count(*) from public.votes where pin_id = ...` check in the SQL Editor. Not verifiable
  from this sandbox.
- **Compile/build/test status.** This sandbox has no Xcode/`xcodebuild`/simulator. I did not (and
  could not) compile this PR or run its test suite. Kevin's reported 842/0 (baseline 830) is taken
  at face value; I independently confirmed via `grep` that the test file contains exactly 12
  `func test...` methods, consistent with 830 + 12 = 842.

## Smoke tests run

This is a Linux-VPS-only static review — no build, no simulator, no live app. What I actually did:

- `git fetch origin && git checkout -B ios/ft2-delete-own-pin origin/ios/ft2-delete-own-pin`, then
  `git status` / `git diff HEAD` — confirmed clean working tree matching `HEAD` before reading
  anything (no drift, unlike the earlier incident this task warned about).
- Read `docs/ft2-delete-own-pin-spec.md` in full and `docs/field-testing-log.md`'s FT-2/FT-3 entries.
- Read the full diff of all 3 changed files (`git diff main...HEAD` on each), not just the PR
  description.
- Traced `deleteCrowdPin`'s control flow by hand for every exit path: auth-guard throw (before any
  state touched), url-construction failure (defensive/effectively unreachable), 2xx return, 404
  return, non-2xx/404 throw + rollback, network-error throw + rollback — confirmed `defer` fires on
  every one of these via Swift's defer-on-scope-exit semantics.
- Traced `pendingOptimisticDeletes` for: single-caller round trip with no echo, single-caller round
  trip with an echo arriving mid-flight (correctly suppresses rollback), single-caller rollback
  followed by a later echo after the entry is already cleared (self-corrects via `removePin`'s
  unconditional removal — confirmed the author's claim), and two concurrent same-id calls (found
  Finding #2).
- Traced `isOwnPin` against: `author_id = null` (open-data pins), Realtime-delivered pins (confirmed
  `author_id` is a base-table column present in WAL payloads, unlike `author_username` which is
  view-only per `RealtimePinChannel.swift:23-29`), and a rotated/stale anon identity (correctly
  resolves to `isOwnPin == false`, and RLS would independently reject the delete too since
  `auth.uid()` wouldn't match the old `author_id`).
- Cross-checked the `pins_delete_own` RLS policy and `votes` FK text directly in
  `supabase/02-pins-schema.sql:156-166` against what the spec cites, and confirmed via
  `git diff main...HEAD --stat -- supabase/` that no migration file was added.
- Confirmed `CommunityPin.swift` was not modified (`git diff main...HEAD --stat` — file absent from
  the diff), matching the AC-D20/AC-I2 invariant the spec calls out.
- Grepped the diff for force-unwraps (`[a-zA-Z0-9_\)]!` excluding `!=`) in the two production files
  — none found.
- Read the full test file (`FT2DeleteOwnPinTests.swift`, 571 lines) and assessed it against real
  service/state assertions (not mock-internals assertions) — confirmed the tests genuinely exercise
  `CommunityPinService.visiblePins` state through a real `URLProtocol`-mocked network boundary, the
  same pattern as `Tier3PinFeedbackTests.swift`'s precedent (verified that file does use per-feature
  mock classes, confirming the stated precedent is real, not just claimed).
- Did **not** build, compile, run tests, or launch a simulator — none available in this environment.
  This PR does not touch `MapViewRepresentable.swift`, `ContentView.swift`, `DriveMode*.swift`, or
  `.safeAreaInset` overlay code, so it is not in the mount-chain-PR class that would otherwise force
  a live-UI smoke gate regardless of environment; a Mac-side build/install/screenshot pass is still
  the only way to close AC-FT2.13(e) and AC-FT2.11 (see above).

## What's working

- The core happy-path and Kevin's already-confirmed offline-rollback behavior are implemented
  exactly as described, and the code's own reasoning for the rollback-vs-Realtime-echo interaction
  is sound and matches what I found by tracing it independently rather than trusting the doc
  comments.
- The ownership predicate is unchanged, minimal, and correct — this PR resisted the temptation
  (flagged as a trap in spec OQ-2) to add a redundant `source == .crowd` check, and reuses the
  pre-existing A1 guard verbatim rather than reimplementing it.
- No migration shipped, and none was needed — the PR correctly relied on the already-live
  `pins_delete_own` policy and `votes` cascade FK rather than generating unnecessary manual work for
  Kevin.
- The `ReactionsRow` split into `deleteSection`/`voteSection` is a clean, minimal-diff refactor — the
  non-own vote code was moved essentially verbatim, not rewritten, which keeps the FT-3-tested vote
  behavior low-risk.
- Test coverage for the rollback/echo interaction (4 dedicated tests: original index preservation,
  403 also rolling back, auth-guard-before-removal, echo-during-failure suppressing rollback) is
  genuinely thorough for the subtlest part of this PR and caught the right edge cases — it just
  stopped one case short of the concurrent-same-id scenario in Finding #2.
