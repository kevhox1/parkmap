# supabase-swift Realtime — Stream B QA Pass 1 — 2026-08-19

**Reviewed:** branch `ios/supabase-realtime-stream-b` at `c2172318`, against
`docs/supabase-swift-realtime-spec.md` (§5, §7, §8, §11, AC-R1–R11).
**Environment:** Linux VPS, no Xcode/simulator. This is a cold static read of the diff — no
build, no test run. The PR is explicitly labeled COMPILE-UNVERIFIED; Kevin compiles on his Mac.
**Verdict:** 🟡 **ship with caveats** — needs one fix (lifecycle race) before/shortly after the
Mac compile, not before merge-to-branch. Do not consider this feature "done" until the race in
Finding #1 is either fixed or explicitly accepted as a known limitation with a tracked follow-up.

## Summary

This is a careful, well-scoped implementation that matches the spec's design closely: one
table-wide subscription (not the wrong two-channel split the old TODO sketched), client-side
viewport + type gating in front of the existing untouched merge core, DELETE-by-primary-key
handling, and a genuinely minimal `ContentView.swift`/scope footprint (zero diff to
`MapViewRepresentable.swift`, zero diff to `RegionSyncGuardTests`). The merge-path correctness
criteria (item 1 in the brief) are solid. The one real gap is lifecycle: `startRealtime()` /
`disconnectRealtime()` / `reconnectRealtime()` don't serialize against each other, so a rapid
background→foreground flap can race a `connect()` Task against a still-in-flight `disconnect()`
Task and leave the app foregrounded with a subscribed-but-actually-unsubscribed channel — with no
self-detection until the next full background/foreground cycle. Combined with the periodic-poll
fallback being suspended during Drive Mode, this is the exact "dead socket + suspended poll =
stale pins at 30mph" scenario the task brief called out as the real product risk, and the new
tests don't exercise it (they explicitly `await` each operation before starting the next, which
sidesteps the race by construction).

## Acceptance criteria checklist

- [x] AC-R1 (unit-testable slice) — `startRealtime()` calls `realtimeChannel.connect(...)`,
      verified by `testStartRealtime_callsConnectOnRealtimeChannel`. Live event-delivery over a
      real socket is explicitly out of reach on this VPS — **not verified**, needs Mac/simulator
      or a direct prod SQL insert per spec §11.
- [x] AC-R2 — `RealtimeMergeGate.isWithinRegion` unit tests cover center/far-outside/padding-edge
      cases correctly (`RealtimeMergeGateTests`, `CommunityPinService.swift:77-92`).
- [x] AC-R3 — eligible in-viewport upsert reaches `mergeRealtimeChange` and appears in
      `visiblePins`; existing 8 merge-core tests are untouched in the diff (confirmed via `git
      diff` — the new tests are pure appends after line 1091).
- [x] AC-R4 — ineligible type and out-of-viewport events are dropped before
      `mergeRealtimeChange`, including the `lastFetchedRegion == nil` edge case
      (`testRealtimeUpsert_noRegionFetchedYet_dropped`).
- [x] AC-R5 — DELETE removes by ID via `removePin(id:)`, no `CommunityPin` decode required;
      confirmed in both `RealtimePinChannel.swift`'s `.delete` case (reads
      `oldRecord["id"]` only) and `CommunityPinService.removePin(id:)`.
- [ ] AC-R6 — **partially verified.** `disconnectRealtime()`/`reconnectRealtime()` are wired to
      the new `.background`/`.active` scenePhase branches, and the existing `.active` logic
      (banner/mute/reminder/deep-link) is untouched — confirmed by diff. But the *sequencing*
      guarantee implied by "wired to lifecycle" (no leaked/duplicate/dead subscriptions across a
      flap) is not actually met — see Finding #1.
- [x] AC-R7 — `setDriveModeActive(true)` leaves Realtime connected and still suspends the poll;
      verified by `testSetDriveModeActive_true_leavesRealtimeConnected_suspendsPeriodicPoll` and
      by reading `setDriveModeActive` (unchanged besides the doc comment).
- [x] AC-R8 — `pinRefreshIntervalSeconds` retuned 8→45s, still a named constant
      (`CommunityPinService.swift:212`), and `PeriodicRefreshSchedulingTests` was updated to
      match (not left stale).
- [x] AC-R9 — `MapViewRepresentable.swift` has zero diff; `ContentView.swift`'s diff is confined
      to the `supabaseClients` property, the init signature, and the `scenePhase` branch/append —
      no camera/overlay code touched.
- [~] AC-R10 — Test suite cannot be run on this VPS. Read-quality assessment: real, not
      rubber-stamp, but with the specific untested branch in Finding #1 (see "Test quality"
      below).
- [x] AC-R11 — Confirmed no diff to `RegionSyncGuardTests` or any camera-adjacent test file.
- [x] AC-C1 — Branch's merge-base with `main` is `main`'s current tip (`4714982b`), which already
      contains FT-15's `CommunityPinService.swift` changes per `HANDOFF.md`'s 2026-08-18
      "FT-15 feature-complete" entry — correctly sequenced, single commit on top.

## Findings

### 🟡 Significant

- **#1: `startRealtime()`/`disconnectRealtime()`/`reconnectRealtime()` are not serialized against
  each other — a fast background→foreground flap can race connect vs. disconnect and leave the
  socket silently dead while the app believes it's live.**
  - Where: `ios/WePark/WePark/Services/CommunityPinService.swift`, the
    `realtimeConnectTask`/`realtimeDisconnectTask` pair (around lines 487-520) and
    `ContentView.swift`'s `handleScenePhaseChange` (around lines 2450-2478).
  - What: `disconnectRealtime()` cancels `realtimeConnectTask` (a `Task.cancel()`, which is
    cooperative — it does **not** interrupt an in-flight `await realtimeChannel.connect(...)`
    call unless that call itself checks `Task.isCancelled`, which
    `SupabasePinRealtimeChannel.connect(...)` never does) and kicks off a **new**,
    un-awaited `realtimeDisconnectTask`. `reconnectRealtime()` → `startRealtime()` does not wait
    for, or cancel, any outstanding `realtimeDisconnectTask` before starting a new
    `realtimeConnectTask`. On a fast background→foreground cycle (real-world trigger: quickly
    switching to another app and back, a fast Siri/notification interruption, or a system dialog
    momentarily backgrounding the app), the previous `disconnect()`'s `await
    channel.unsubscribe()` / `realtimeClient.disconnect()` can complete **after** the new
    `connect()`'s `await ch.subscribeWithError()` — because `connect()`'s own idempotency guard
    (`guard ch.status != .subscribed, ch.status != .subscribing else { return }`,
    `RealtimePinChannel.swift:160`) can see a stale `.subscribed` status left over from before
    the race and skip re-subscribing entirely, while the losing `disconnect()` call still tears
    the socket down moments later. End state: `CommunityPinService` believes Realtime is running
    (no error surfaced anywhere), but the channel is actually unsubscribed/disconnected. Nothing
    self-detects this — the app has to background and foreground again (a full clean cycle) to
    recover, or wait for the 45s poll (which is suspended during Drive Mode).
  - Expected: spec §5.3 describes exactly one channel across scenePhase transitions with no leak
    or double-subscribe; implicitly this also means no *silent dead* state either. The task brief
    specifically asked "Can a rapid background/foreground flap leave the service subscribed-but-
    dead or double-subscribed?" — yes, it can end up subscribed-but-dead.
  - Repro (cannot execute without Xcode — reasoning from the code, not an observed run): drive a
    fast `.active → .background → .active` scenePhase sequence within roughly the round-trip time
    of one `unsubscribe()`/`disconnect()` network call (sub-second on a real socket), e.g. by
    calling `handleScenePhaseChange(.background)` immediately followed by
    `handleScenePhaseChange(.active)` without awaiting anything in between — which is exactly what
    a real fast app-switch does. The new test suite never does this: every
    `CommunityPinServiceRealtimeWiringTests` test explicitly `await`s
    `realtimeConnectTask?.value`/`realtimeDisconnectTask?.value` before issuing the next call
    (e.g. `testReconnectRealtime_callsConnectAgain`), which sidesteps the race by construction and
    would pass even if this bug is real.
  - Why this matters more than a generic edge case: this compounds directly with the Drive-Mode
    poll suspension the brief called out as the actual product risk. If the race lands while Kevin
    is driving (e.g., he glances at a text and the app backgrounds/foregrounds quickly, or a phone
    call banner causes a fast scenePhase flap) and Drive Mode is then active or already active,
    pins go stale with **zero** live-update mechanism (dead socket, suspended poll) until he exits
    Drive Mode or does a full background/foreground cycle — with no UI signal that anything is
    wrong.
  - Suggested fix direction (not prescriptive — `@ios-engineer`'s call): serialize connect/
    disconnect/reconnect through a single chained `Task` (e.g. `realtimeLifecycleTask = Task { [weak
    self] in await self?.realtimeLifecycleTask?.value; await ... }`) or an actor-owned state
    machine, so a new lifecycle operation always waits for the prior one to finish before starting.
  - Owner: `@ios-engineer`

### 🟢 Minor / nit

- **#2: No test exercises the actual reconnect-gap staleness window this feature exists to close.**
  - Where: `CommunityPinServiceRealtimeWiringTests` in `CommunityPinServiceTests.swift`.
  - What: There's no test asserting that a pin inserted *while disconnected* (simulated: connect →
    disconnect → simulate a DB-side insert that would have fired had the socket been up → reconnect
    → `refetchCurrentRegion()`) actually shows up after the reconnect+refetch belt-and-suspenders
    path. This is exactly the "close the gap of events missed while disconnected" behavior the spec
    calls out in §5.3. It's arguably more of an integration concern than a unit-test gap (the mock
    can't simulate "an event happened while nobody was listening" meaningfully), so I'm not
    blocking on it, but it's worth a live/simulator check alongside AC-R1.
  - Owner: `@ios-engineer` (test) or QA follow-up (live check).

- **#3: `RealtimeMergeGate.isWithinRegion` bounding-box math will misbehave near the antimeridian
  (lng ±180°) or over the poles.**
  - Where: `RealtimeMergeGate.swift:77-92`.
  - What: Plain min/max longitude comparison, no wraparound handling. Not a real risk for a
    NYC-only app — flagging only because it's a silent, easy-to-miss latent bug if this code is
    ever reused for a different market. No action needed now.
  - Owner: n/a — logged for future reference only.

### 💡 Out of scope (logged, not fixed)

- **The Drive-Mode "no fallback if the socket drops silently" tradeoff is exactly as spec'd
  (§5.4, §7), not an implementation bug** — flagging again here per the task brief's explicit ask,
  because it's the single biggest thing for Kevin to internalize about this feature's risk profile:
  if `RealtimeClientV2`'s own internal reconnect (opaque to this app's code) ever fails to recover
  a dropped connection during an active Drive Mode session, pins go stale for the **entire
  remainder of the drive**, with zero code-level detection or mitigation. `isConnected` is exposed
  on `RealtimePinSubscribing` (OQ-4) but nothing acts on it. This was an explicit, stated tradeoff
  in the spec, not something this PR should be blocked on — but Finding #1 above shows there's now
  a *second*, implementation-introduced way to reach the same dead-socket-during-Drive-Mode state
  (not just "the SDK's reconnect silently fails," but "our own lifecycle code raced itself"), which
  raises the practical odds of hitting this scenario above what the spec's authors were accounting
  for.
- **`emitLocalSessionAsInitialSession: true` was correctly declined.** Read the inline reasoning in
  `SupabaseClients.swift:100-114` and independently traced the logic described (persisted-and-
  expired session emits the stale session synchronously first, then refreshes in the background,
  under `true`, vs. only ever emitting an already-fresh/cleaned-up session under `false`). Given
  `validAccessToken()` re-checks via `authClient.session` on every call and never trusts the cached
  property, and given this is a Realtime PR that shouldn't also be silently changing Auth
  event-ordering semantics, deferring is the right call. Agree with the PR author's own conclusion.
- **`RealtimeClientV2`/`RealtimeChannelStatus`/`AnyAction` API surface is COMPILE-UNVERIFIED by
  necessity of this environment.** The PR's self-disclosure is honest and specific (exact pinned
  SDK revision + files read). I could not independently verify these symbols exist with the stated
  shapes; this genuinely requires the Mac `xcodebuild build && test` pass called out in the PR
  description and the spec's own gate. Not treating this as a finding since it's already flagged
  and expected — just restating it's still unverified after this pass.
- **`SupabaseClients: Sendable` holding `RealtimeClientV2` as a stored `let`.** Whether the SDK's
  `RealtimeClientV2` actually conforms to `Sendable` (required for the struct's own `Sendable`
  conformance to hold) is unverifiable here. `SWIFT_VERSION = 5.0` in the pbxproj (confirmed via
  grep) means even if this is imperfect it will very likely surface as a warning, not a hard
  error, so I'm not blocking on it — but it's a specific thing to watch in the Mac build log.

## Smoke tests run

- **Read the full diff** (`git diff main...ios/supabase-realtime-stream-b`) file-by-file:
  `CommunityPinService.swift`, `RealtimeMergeGate.swift`, `RealtimePinChannel.swift`,
  `SupabaseClients.swift`, `WeParkApp.swift`, `ContentView.swift`,
  `CommunityPinServiceTests.swift`, `SupabaseAuthServiceTests.swift`,
  `Tier3PinFeedbackTests.swift`. Outcome: matches spec design closely; one lifecycle race found
  (Finding #1).
- **Traced the merge/gate path by hand** for INSERT/UPDATE/DELETE against `mergeablePinTypes`,
  viewport gating, resolved/expiry handling, and duplicate-prevention (upsert-by-ID vs. wholesale
  REST replace on `fetchPins`). No gaps found beyond spec-acknowledged ones.
- **Traced the connect/disconnect/reconnect task lifecycle by hand**, cross-referenced against the
  new test suite's own await patterns. Confirmed the race is real in the code and confirmed the
  tests structurally cannot catch it (they serialize by awaiting each op).
- **Confirmed `struct SupabaseClients: Sendable` calling a `@MainActor`-isolated
  `SupabasePinRealtimeChannel` initializer synchronously is not a cross-actor hazard** — checked
  `project.pbxproj` and confirmed `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide
  (both Debug/Release configs), which matches the pre-existing precedent of `CommunityPinService`
  (also `@MainActor`) already being constructed synchronously from `ContentView.init()` before this
  PR. Not a new risk.
- **Checked for the "`let` with default value excluded from synthesized memberwise init" trap**
  in every new/changed struct. `SupabaseClients` is the only new-ish struct with stored `let`
  properties and it has fully explicit custom initializers (no synthesized memberwise init relied
  on anywhere) — trap does not apply here.
- **Confirmed zero diff** to `MapViewRepresentable.swift` and `RegionSyncGuardTests` (AC-R9/R11) via
  `git diff --stat`.
- **Confirmed the branch point** (`git merge-base`) is `main`'s current tip, which already contains
  FT-15's `CommunityPinService.swift` changes (AC-C1) — not just "it compiled," per the task's own
  instruction to actually check the branch point.
- **Grepped for `Calendar.current`** across every touched file — zero hits (AC-A4-class invariant
  holds for this PR too, even though it's not directly an Auth-stream PR).
- **Cross-checked** the `SupabaseAuthServiceTests.swift` restored-test claim against
  `docs/qa/supabase-auth-keychain-stream-a-qa.md` Finding #1 — the characterization in this PR's
  header comment is accurate (4 of 5 removed tests had equivalents, 1 didn't, this PR restores it).
- **Did NOT and could NOT run**: `xcodebuild`, any XCTest target, any simulator. No live-socket
  event-delivery check (AC-R1's live half) was performed — this remains genuinely unverified until
  Kevin's Mac pass.

## What's working

- The one-table-wide-subscription design is implemented exactly as the spec's §5.1 reasoning
  requires (not the wrong two-channel split the old TODO comment described), and the PR's own
  comments correctly explain *why*, not just *what* — this will save the next reader real time.
- `RealtimeMergeGate` is a clean, pure, well-tested extraction — good padding-boundary test
  coverage (exact edge, inside-padding, outside-padding all covered).
- DELETE handling correctly avoids the `REPLICA IDENTITY FULL` trap by only ever reading the
  primary key, matching the spec's explicit "no schema change" constraint.
- `[weak self]` used consistently in every closure that crosses the connect/disconnect boundary —
  no retain-cycle risk found.
- Scope discipline is excellent: zero `MapViewRepresentable.swift` diff, zero `RegionSyncGuardTests`
  diff, `ContentView.swift`'s diff is genuinely minimal and additive (one new branch, two appended
  lines to the existing `.active` branch) — this correctly protects the FT-20 bottom-sheet work
  that's serialized behind this PR.
- The PR proactively closed a QA finding from the *prior* stream (Stream A's dropped
  `testEnsureSession_expiredToken_callsRefresh` coverage) rather than leaving it for someone else to
  notice — good cross-PR QA hygiene.
- Honest, specific COMPILE-UNVERIFIED disclosure with the exact SDK revision and files inspected,
  not a vague disclaimer.

---

# Pass 2 — 2026-08-19

**Reviewed:** branch `ios/supabase-realtime-stream-b` at `0000b636`, scoped to the fix commit
`0000b636` ("fix(ios): serialize Realtime connect/disconnect/reconnect lifecycle (QA #84 Finding
#1)") against Pass 1's Finding #1. Not a re-review of the whole feature.
**Environment:** Linux VPS, no Xcode/simulator — static read only, same constraint as Pass 1.
Per the task brief, Kevin's Mac run (iPhone 17, iOS 26.5) is accepted as given: **730/730 passed,
0 failed, 0 skipped**, including the new `testDisconnectThenReconnectFlap_doesNotRaceAndEndsConnected`
(`CommunityPinServiceTests.swift:1465`). Compile is proven; this pass is about whether the fix is
*correct* and whether chaining introduces a new failure mode, not whether it builds.
**Verdict:** ✅ **MERGE**

## Summary

The fix replaces `Task.cancel()`-and-replace with a chained-Task serial queue
(`realtimeLifecycleTask`), and it genuinely closes Pass 1 Finding #1 — traced by hand against both
the real `SupabasePinRealtimeChannel` (`RealtimePinChannel.swift:160`'s idempotency guard, which
is otherwise unchanged) and the new test. The chaining pattern is a well-known, correct concurrency
idiom (an async serial queue via task-linking); I could not construct a cycle, deadlock, or
unbounded-retain scenario against it, and the regression test reproduces the exact previously-
broken interleaving rather than a synthetic one. One real, intentional behavioral trade-off is
introduced (a rapid multi-flap now costs the *sum* of each queued op's round-trip time before the
final state lands, instead of racing them), which is the correct trade for this feature but is
worth Kevin knowing about explicitly. No blocking findings.

## What I verified

**1. Does the fix close Finding #1?** Yes. Traced the full causal chain:

- `CommunityPinService.swift` is `@MainActor`-isolated at the class level, and
  `startRealtime()`/`disconnectRealtime()` are synchronous, non-`async` methods — so
  `let predecessor = realtimeLifecycleTask` followed by `realtimeLifecycleTask = task` inside each
  of them cannot be interleaved by a concurrent call to the other; there is no await between those
  two lines, and both methods only ever run on the main actor. This means the *property itself* is
  race-free, and the ordering of who becomes whose `predecessor` is fully deterministic and matches
  call order.
- Each new `Task`'s body unconditionally does `await predecessor?.value` as its literal first
  line, before touching `realtimeChannel` at all. Since `predecessor`'s own body did the same thing
  for *its* predecessor, this recurses back to the start of the chain — awaiting any single task's
  `.value` transitively waits for every earlier queued operation to have fully finished, not just
  the immediately preceding one. Confirmed this holds for the specific two-deep case exercised by
  the new test and holds by induction for arbitrary chain depth.
- Because `disconnect()`'s real implementation (`RealtimePinChannel.swift:172-183`) unsubscribes
  and disconnects the client *before* returning, and a subsequent `connect()` cannot start until
  that full disconnect has returned, the stale-`.subscribed` read at `RealtimePinChannel.swift:160`
  that Pass 1 identified is no longer reachable via the flap path — not narrowed, actually
  eliminated, because by the time `connect()` runs, `ch.status` has already been driven to
  unsubscribed by the disconnect that necessarily ran first.
- The new test (`CommunityPinServiceTests.swift:1465`,
  `testDisconnectThenReconnectFlap_doesNotRaceAndEndsConnected`) reproduces the *exact* interleaving
  from Pass 1's repro steps — `disconnectRealtime()` immediately followed by `reconnectRealtime()`
  with no `await` in between, i.e. `handleScenePhaseChange(.background)` immediately followed by
  `handleScenePhaseChange(.active)` — with an artificial 200ms `disconnectDelay` to make the old
  race's failure mode observable, plus a 300ms wall-clock buffer that's belt-and-suspenders (see
  §3 below on why it's not load-bearing for the fixed code, only for demonstrating the pre-fix
  failure). This is not a synthetic strawman test; it targets the real bug.

**2. New failure modes from chaining — this was the priority.**

- **Unbounded chain growth / retain: not present.** `realtimeLifecycleTask` only ever holds the
  current tail (each call unconditionally overwrites it). A given `Task`'s closure captures only
  its immediate `predecessor`, not the whole history — so memory is bounded to O(1) per link, and
  once a task's body has passed its `await predecessor?.value` line, nothing in that closure
  references the ancestor chain further back. This is the standard "async serial queue via
  task-linking" pattern, not an accumulating list.
- **Deadlock / self-await: not possible.** `predecessor` is bound to the *old* value of
  `realtimeLifecycleTask` before the new `Task` closure is even constructed, so a task can never
  end up as its own predecessor, and there's no shared-lock/semaphore construct here that could
  form a cycle — just plain `await`, which yields cooperatively and cannot deadlock the way a
  blocking primitive could.
- **Cancellation semantics — the engineer's claim is accurate, with one trade-off worth
  surfacing explicitly.** Every requested op does now run, in request order, and — this is the
  part that matters — because each op fully replaces the app's belief of Realtime state, the *final*
  state after a chain settles is always correct regardless of chain depth: if the flap sequence
  ends on `.active`, the last queued op is a connect and the channel ends up connected; if it ends
  on `.background`, it ends up disconnected. I verified this isn't just true for the 2-deep case
  the test covers — it's a structural property of the "each task awaits only its immediate
  predecessor, in call order" design and generalizes to N-deep flapping. **The trade-off**: a rapid
  5x background/foreground flap (Kevin's example in the task brief) now executes five full
  connect/disconnect round trips *serially* rather than racing them, so the fifth operation's
  latency is the sum of the previous four's round-trip times, not just its own. Pre-fix, the racing
  behavior could in theory "finish faster" but land in a wrong/inconsistent state (that was the
  whole bug). This is a deliberate and correct trade of latency for correctness, appropriate for a
  background socket the user isn't watching in real time — but it does mean an extreme flap
  scenario (rapid app-switcher spam) could delay the Realtime socket coming back for a couple of
  seconds after the user settles on the foreground. Not a bug; a real-and-worth-knowing consequence.
- **Removed `Task.cancel()` — stranding / lifetime check.** `CommunityPinService` is instantiated
  exactly once, as a `State`-owned property in `ContentView` (`ContentView.swift:642`), and lives
  for the entire process — there is no `deinit` on this class before or after this fix, and no
  code path that creates a second instance mid-session. So there is nothing to "strand" on genuine
  app termination that wouldn't already be terminated with the process; this precedent already
  existed for `realtimeConnectTask`/`realtimeDisconnectTask` pre-fix (no cancel-on-deinit there
  either) and is unchanged by this commit. `[weak self]` is used consistently in both new `Task`
  closures (`startRealtime()`'s body does `guard let self else { return }` after the predecessor
  await; `disconnectRealtime()`'s body uses `self?.realtimeChannel.disconnect()`), so a
  hypothetical future teardown wouldn't crash or retain the service artificially — it would just
  silently no-op the tail of the chain, which is the right behavior.

**3. Test honesty — confirmed, not flaky-by-construction.**

- `connectDelay`/`disconnectDelay` are declared inside `MockRealtimePinChannel`, and the entire
  class is wrapped in `#if DEBUG` (`RealtimePinChannel.swift:255-320`) — this is a test-only seam,
  matching the pre-existing `#if DEBUG` precedent already used for
  `SupabaseAuthService.swift`'s `InMemoryAuthStorage`. No production code path branches on these
  properties; `SupabasePinRealtimeChannel` (the real implementation) has no delay knobs at all.
- The 200ms mock `disconnectDelay` + 300ms wall-clock buffer are **not load-bearing for the fixed
  code's correctness**, which is a good thing, not a gap: the primary assertion path is gated by
  Swift concurrency's causal guarantee (`await service.realtimeConnectTask?.value` cannot return
  until the connect task's body has finished, and that body's first line is
  `await predecessor?.value`, i.e. the disconnect task) — not by wall-clock timing. The extra
  300ms sleep only matters for making the *pre-fix* regression observable (per the test's own
  inline comment) and is otherwise inert on the fixed code; it cannot cause a false pass under
  timing pressure, and on a slower CI machine it can only add latency to the test run, not flip an
  assertion. I don't see a flake risk here.
- One test-suite gap worth naming (not blocking): the new test covers exactly one flap (a 2-deep
  chain — one disconnect, one connect). Deeper flapping (3+) is not directly exercised, though the
  mechanism generalizes by the same induction argument in §2 above. Logged as a minor follow-up,
  not a blocker, since the mechanism being tested is depth-independent by construction.

**4. Scope regression check — clean.**
`git diff main...ios/supabase-realtime-stream-b --stat` shows no `MapViewRepresentable.swift`
entry at all (zero diff, same as Pass 1), and `ContentView.swift` is still the same 52-line,
scenePhase-only diff Pass 1 characterized — the fix commit did not touch `ContentView.swift`. The
`.background`/`.active` scenePhase wiring at `ContentView.swift:2452-2481` is unchanged from Pass 1
and still confined to the documented single new branch plus two appended lines.

**5. Synthesized-init trap.** No new `struct` was introduced by this fix commit (it only adds
properties/methods to the existing `final class CommunityPinService` and `final class
MockRealtimePinChannel`, both classes with no memberwise-init reliance). Not applicable —
informational only, as instructed.

## Findings

### 🟢 Minor / nit

- **#4: New race test only exercises a 2-deep chain (one flap), not deeper rapid flapping.**
  - Where: `CommunityPinServiceTests.swift:1465`,
    `testDisconnectThenReconnectFlap_doesNotRaceAndEndsConnected`.
  - What: The test proves the mechanism for a single disconnect→reconnect flap. A 3+ deep chain
    (e.g. background→active→background→active→active within a fraction of a second) is not
    directly tested, though the serialization mechanism is depth-independent by construction (see
    Pass 2 §2) and I'm confident it generalizes.
  - Suggested: a follow-up test with 3+ queued ops and mixed delays, for extra confidence — not
    blocking.
  - Owner: `@ios-engineer` (follow-up, non-blocking).

### 💡 Out of scope (logged, not fixed)

- **Latency trade-off of serialization vs. racing is real and worth Kevin knowing before merge,
  even though it's the correct trade.** Under extreme rapid app-switcher flapping (5+ flaps in
  under a second — an edge case, not a normal user action), the Realtime socket now takes the sum
  of all queued round trips to settle into its final state, rather than potentially settling
  faster-but-wrong under the old racing code. This is the right trade for a background socket, and
  is not a bug, but it's a behavioral change from "fast and sometimes silently broken" to "possibly
  a couple seconds slower and always eventually correct" that's worth having in mind if anyone ever
  reports "pins took a moment to catch up after switching apps a bunch."
- **Pass 1 Findings #2 (reconnect-gap test) and #3 (antimeridian) are unchanged by this commit** and
  remain deliberately not actioned per the task brief — not re-raised here.

## Smoke tests run

- **Read `git show 0000b636`** in full against all three touched files
  (`CommunityPinService.swift`, `RealtimePinChannel.swift`, `CommunityPinServiceTests.swift`).
- **Hand-traced the causal chain** of `realtimeLifecycleTask` / `predecessor` capture across
  `startRealtime()`/`disconnectRealtime()`, confirming: no data race on the property (both callers
  are synchronous `@MainActor` methods, no intervening `await`), no self-await/cycle (`predecessor`
  is bound to the old value before the new `Task` is constructed), and transitive-wait-spans-whole-
  chain by induction.
- **Re-read `RealtimePinChannel.swift:128-183`** (the real `SupabasePinRealtimeChannel.connect()`/
  `.disconnect()`) to confirm the stale-`.subscribed` guard at line 160 is genuinely unreachable
  post-fix, not just narrowed — confirmed unchanged by this commit, and confirmed the ordering
  guarantee from the chain is what closes the window, not a change to the guard itself.
- **Confirmed `#if DEBUG` scope** of `MockRealtimePinChannel` and its new `connectDelay`/
  `disconnectDelay` knobs — test-only, no production branching added.
- **Grepped for lingering `.cancel()` calls** on the three realtime task properties — none remain,
  confirmed the old `realtimeConnectTask?.cancel()` / `= nil` lines were fully removed, not
  half-migrated.
- **Checked `CommunityPinService` instantiation site** (`ContentView.swift:642`) — single instance,
  app-lifetime `State` property, no `deinit` before or after this commit — confirmed the "no
  cancel-on-deinit" observation isn't a new gap introduced by this fix.
- **Checked existing tests around the new one** (`testDisconnectRealtime_callsDisconnectOnRealtimeChannel`
  at line 1364, `testReconnectRealtime_callsConnectAgain` at line 1377,
  `testSetDriveModeActive_true_leavesRealtimeConnected_suspendsPeriodicPoll` at line 1392) — none
  assert `realtimeConnectTask == nil` after a disconnect, so removing the old
  `realtimeConnectTask = nil` line inside `disconnectRealtime()` doesn't silently break them.
- **`git diff main...ios/supabase-realtime-stream-b --stat`** — confirmed `MapViewRepresentable.swift`
  absent (zero diff) and `ContentView.swift` unchanged at 52 lines from Pass 1 (this fix commit
  touched only the three files it claims to).
- **Did NOT and could NOT run**: `xcodebuild`, XCTest, or a simulator — same Linux-VPS constraint
  as Pass 1. Per the task brief, Kevin's Mac run (730/730 passed) is accepted as given and not
  re-verified here; this pass is a logical/adversarial trace of the fix's correctness, not a
  compile check.

## What's working

- The fix is a textbook-correct application of task-chaining as a serial queue — a well-established
  Swift concurrency idiom — applied precisely at the point Pass 1 identified as broken, with no
  scope creep into other files.
- The regression test targets the *actual* previously-broken interleaving (no-await-between-calls),
  not a synthetic stand-in, and its inline commentary honestly explains both the pre-fix failure
  mechanism and why the post-fix assertion holds — genuinely useful for the next reader.
- `[weak self]` discipline is maintained in both new `Task` closures, consistent with the rest of
  the file's precedent.
- The commit message is unusually good bug-tracking hygiene: it cites the exact QA finding it
  closes, explains why the old approach failed (cooperative cancellation not being observed by the
  SDK calls), and explicitly documents the one thing it deliberately did NOT do (the reconnect-gap
  test from Pass 1 Finding #2) with a stated reason, rather than silently dropping it.
- Doc comments on `realtimeLifecycleTask`/`realtimeConnectTask`/`realtimeDisconnectTask` correctly
  explain the "awaiting either now spans the whole chain" property, which I independently verified
  is true rather than just asserted.
