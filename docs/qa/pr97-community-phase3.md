# Community 2.0 Phase 3 (build 20 S9) — reactions, profile row, leaderboard

**Pass 1 reviewed:** branch `ios/community-phase3` at `480901ed`.
**Pass 2 reviewed:** same branch at `e9fb9e8c` (fix commit for Pass 1's findings).
Both against `docs/community-2.0-reconciliation-spec.md` §3 Phase 3 (AC-P3.1–P3.4) + roadmap S9 +
`design/prototype.html:161-189,941-946` + `design/screenshots/05-feed-full.png`. Schema ground
truth: `supabase/03-community-2.0-schema.sql` (already applied — `claim_pin` RPC §2.10,
`profiles_select_all` RLS, `pins_with_author` view).

**FINAL VERDICT (Pass 2): MERGE-AFTER-MAC-GATE.** All four Pass 1 findings (#1–#4) verified fixed
cold at `e9fb9e8c`, including the adversarial race-interleaving trace for Finding #1. No new
blocking or significant issues found. One new minor observation (visible leaderboard flash on
every zone switch) is logged as an accepted v1 trade-off, not a defect. Kevin's gate is
unchanged in shape from Pass 1 (Mac toolchain build/test + a flag-on visual check); expect
1111/1111 tests.

---

## Pass 1 (below, superseded findings kept for history)

**Verdict at Pass 1: MERGE-AFTER-MAC-GATE** (two 🟡 findings should be fixed before or shortly
after merge — both were fixed in Pass 2, see below).

### Summary

This is a clean, well-scoped Phase 3 PR. The core architectural claim — both `PinDetailSheet.ReactionsRow`
and `CrewFeedSection.PinFeedRow` route through the same pure `CommunityPin.reactionsRowKind(currentUserId:)`
— is true, verified by reading both call sites (not assumed). The `claimPin` write path matches
the applied `claim_pin(p_pin_id uuid)` RPC exactly (parameter name, auth header, boolean-scalar
decode, race-safe `false` handling). All three disclosed deviations are reasonable and correctly
characterized. The one undisclosed gap is a leaderboard zone-switch race (no request
generation/cancellation guard) that can show stale cross-zone data — the exact failure mode
AC-P3.4 explicitly rules out — plus a related "keep old data on fetch failure" choice that has the
same effect. Neither is severe enough to block merge (this is UI polish behind `communityEnabled`,
not a data-integrity or security issue), but both should be fixed, ideally before Kevin's TestFlight
gate opens.

### Acceptance criteria checklist

- [x] AC-P3.1 — Confirm tap still awards +2 rep/+1 helped-count and extends `expires_at` via the
      existing `upsertVote`/`callExtendPinExpiry` calls, unchanged, for every type that routes to
      `.vote` (including the new `open_spot`). Verified by reading `PinFeedRow.handleStillThere`
      and `ReactionsRow`'s unchanged `voteSection`/`handleStillHere` — both call the same,
      pre-existing service methods; Phase 3 didn't fork a parallel path. `leaving_soon` correctly
      never reaches `.vote` (claim-only), so this AC's "including the two new types" is satisfied
      for `open_spot` and correctly inapplicable to `leaving_soon`.
- [x] AC-P3.2 — "Gone" still maps to `upsertVote(pinId, .dispute)`, the existing 3-vote
      auto-resolve mechanism; no new decay code. Confirmed no `expires_at`-shrinking code
      anywhere in the diff.
- [x] AC-P3.3 — `ProfileRowFormatting.accuracyLabel(accurate: 0, total: 0)` returns `"—"`,
      verified in both the formatting tests (4 boundary cases) and the one production call site
      (`profileSubLine`). Divide-by-zero guarded (`guard total > 0 else`).
- [ ] AC-P3.4 — **Partially fails.** `loadLeaderboard(zone:)` is invoked correctly on every zone
      switch, but (a) it's not cancellation-safe against out-of-order completion when a user
      switches zones twice quickly, and (b) a fetch failure deliberately leaves the previous
      zone's entries on screen. Both can result in the leaderboard showing a different zone's
      data than the currently-selected zone chip. See Finding #1. **Fixed in Pass 2 — see below.**

### Findings

#### 🔴 Blocking

None.

#### 🟡 Significant

- **#1: Leaderboard can show stale/wrong-zone data after a fast zone switch or a fetch hiccup — the exact thing AC-P3.4 rules out** — **FIXED in Pass 2.**
  - Where: `Views/CrewFeedSection.swift`, `CrewFeedSection.loadLeaderboard(zone:)` (called from
    `.onAppear`'s `Task` and `.onChange(of: selectedZone)`'s `Task`).
  - What: `loadLeaderboard(zone:)` fires an unstructured `Task { await loadLeaderboard(zone: newZone) }`
    on every zone change with no generation counter, no `.task(id: selectedZone)` cancellation,
    and no check that `selectedZone` still equals the `zone` parameter when the fetch resolves.
    Two related failure modes:
    1. **Out-of-order completion:** user taps Nolita → SoHo → LES quickly. If Nolita's request
       (fired first) resolves *after* LES's (e.g. it happened to hit a slower network path),
       `leaderboardEntries` gets unconditionally overwritten with Nolita's data while the header
       still reads "LES". This is a plain race — nothing prevents an older in-flight `Task` from
       winning the write.
    2. **Fetch failure keeps stale data:** `loadLeaderboard`'s own doc comment states the
       (deliberate) choice: "A fetch failure leaves the previous zone's entries showing rather
       than blanking the section." On a network hiccup during a zone switch, the *previous*
       zone's leaderboard rows stay visible under the *new* zone's header, indefinitely (nothing
       retries), with no stale-data indicator.
  - Expected: AC-P3.4 — "Leaderboard updates within one zone-switch — no stale cross-zone data
    shown."
  - Repro (case 2, the more likely one in practice — no fast-tapping needed): switch to a zone
    while offline or mid-hiccup; the leaderboard silently keeps showing the previously-selected
    zone's ranked authors under the new zone's chip/header, with no error state and no way to
    tell it's stale.
  - Fix shape: standard SwiftUI fix is `.task(id: selectedZone) { await loadLeaderboard(zone: selectedZone) }`
    instead of manual `Task {}` in `onChange`/`onAppear` — this auto-cancels the prior in-flight
    task on every `id` change, closing both failure modes for free. If a "keep old data on
    transient failure" UX is still wanted, it needs an explicit staleness affordance (e.g. clear
    `leaderboardEntries` to `[]` immediately on zone change, or badge the section as stale),
    not silent carry-over.
  - Owner: `@ios-engineer`

- **#2: Leaderboard fetch has no `limit`/`order` — unbounded result size for a busy zone** — **FIXED in Pass 2.**
  - Where: `Services/CommunityPinService.swift`, `buildLeaderboardRequest(zoneId:sevenDaysAgoISO:)`.
  - What: The PostgREST query filters by `source=eq.crowd`, `confirm_count=gt.0`,
    `created_at=gte.<7d ago>`, and the zone's lat/lng box, but has no `limit=` or `order=`
    query param. The client then downloads the entire matching row set and ranks/truncates to
    top-5 in `CommunityLeaderboard.build` on-device. For a quiet MVP zone this is fine; it stops
    being fine the moment a zone genuinely gets busy (the whole point of the feature). Whether
    this silently degrades depends on Supabase's project-level `db-max-rows` default, which isn't
    verifiable from this repo.
  - Expected: task brief's "efficiency sanity: bounded data, not the whole zone's pin history."
    This is bounded by *time* (7 days) and *predicate* (confirm_count>0) but not by *count*.
  - Fix shape: add `order=confirm_count.desc&limit=200` (or similar) — cheap, defensive, doesn't
    change today's behavior for realistic MVP volume.
  - Owner: `@ios-engineer`

#### 🟢 Minor / nit

- **#3: "Someone's heading there" copy doesn't distinguish the claimant's own successful claim** — **FIXED in Pass 2.**
  - Where: `Views/PinDetailSheet.swift` `ReactionsRow.claimSection`; `Views/CrewFeedSection.swift`
    `PinFeedRow.leavingSoonAction`. Both: `if pin.claimedBy != nil { Label("Someone's heading
    there — first come, first served"...) }` — unconditional, doesn't check
    `pin.claimedBy == currentUserId`.
  - What: The prototype (`design/prototype.html:207`) explicitly differentiates: "You're heading
    there — first come, first served" (own claim) vs the generic tag for anyone else's claim
    (`f.claimedTag` vs `f.claimable`). The shipped code always shows the generic "someone" copy,
    even to the person who just tapped the button and won. Once `pin.claimedBy` updates via
    Realtime to the current user's own id, they see impersonal copy about their own action. This
    is a real, if small, undisclosed deviation from the prototype's copy — not called out in the
    PR body's three-item deviation list, though it has the same "reasoned before shipping" spirit
    as those three.
  - Also related: no optimistic UI update on a successful claim (`claimed == true` sets no local
    state), so between tap-success and the next Realtime tick the button is still tappable. A
    re-tap by the same user in that window calls `claim_pin` again, which correctly returns
    `false` (already claimed by them) — but the UI then shows them "someone beat you to it" for
    their own successful claim. Low-probability window (typically sub-second per this repo's
    existing Realtime cadence), and this pattern is consistent with the codebase's existing
    precedent (`upsertVote` also has no optimistic patch) — not a regression, just an inherited
    rough edge worth tightening given it's copy-visible.
  - Owner: `@ios-engineer` (bundle with #1 if convenient — same file).

- **#4: Minor error-copy inconsistency between the two claim call sites** — **FIXED in Pass 2.**
  - Where: `PinDetailSheet.swift` `handleClaim`: `"Couldn't claim — please try again."` vs.
    `CrewFeedSection.swift` `PinFeedRow.handleClaim`: `"Couldn't claim — try again."`. Cosmetic
    only, not user-facing enough to matter, noting for completeness.
  - Owner: `@ios-engineer`

#### 💡 Out of scope (logged, not fixed)

- **Leaderboard avatars.** Confirmed via `supabase/03-community-2.0-schema.sql:635-660`:
  `pins_with_author` selects `pr.username`/`pr.reputation` but not `pr.avatar`. This is genuinely
  a one-line view change (`pr.avatar as author_avatar`) plus a matching iOS decode field — cheap
  enough that it's worth a tracked follow-up ticket rather than a permanent gap, but reasonable to
  defer out of this PR (no schema-migration authority for an iOS agent anyway, per the standing
  "Kevin applies migrations" rule). Recommend a one-line note in `docs/community-2.0-roadmap.md`
  pointing at this exact view + column so it doesn't silently evaporate.
- **A true weekly-reset leaderboard ledger** (`reputation_events`) — already logged in the spec's
  §5 out-of-scope list; this PR correctly ships the live-query approximation instead. No new
  action needed.
- **MapKit POI storefront naming**, **true NTA polygon zones** — pre-existing spec §5 deferrals,
  untouched by this PR, nothing new to log.

### Deviation ruling (task's three disclosed + the one undisclosed one found above)

1. **Tenure copy (duration-based, not "On {street} since {month}") — ACCEPTABLE, correctly
   reasoned.** Verified: no per-user home-street column exists in `profiles` or
   `pins_with_author` (grep-confirmed against `supabase/03-community-2.0-schema.sql`'s `profiles`
   ALTER and the view's SELECT list). Fabricating a street the app doesn't have data for would be
   worse than the honest duration-based substitute. The authoritative spec's own §3 Phase 3
   wording ("tenure (`now() - profiles.created_at`, already available)") supports this reading
   over the dispatch's prototype-quoted copy. **Rule: accept as shipped, record only.**
2. **Leaderboard ranked by confirmed-report count, not the prototype's `pts` rep-points column —
   ACCEPTABLE, correctly reasoned.** The authoritative spec's own §3 Phase 3 text says "count of
   pins they authored with `confirm_count > 0`" — literally what's implemented. The prototype's
   `pts` column is demo-fixture shorthand for a metric (lifetime rep) this session correctly
   identified as unbounded and a different question than "this week's confirmed reports." **Rule:
   accept as shipped, record only.**
3. **No avatars for other neighbors' leaderboard rows — ACCEPTABLE for this PR, queue the
   follow-up.** See "Out of scope" above — genuinely a one-line schema-view change, not deferred
   out of laziness; correctly not attempted here given no migration-apply authority. **Rule:
   accept as shipped; open a tracked one-line follow-up ticket referencing the exact view/column,
   don't let it evaporate the way `02e`'s TODO nearly did.**
4. **Tickets-dodged stat card skip — the reasoning holds, verified rather than rubber-stamped.**
   Checked `supabase/03-community-2.0-schema.sql` and `02-pins-schema.sql` for any column or
   query that could honestly back "a ticket that would have been issued but wasn't" — there is
   none (no counterfactual-enforcement-outcome data exists anywhere in the schema; `pins` records
   what *did* happen, not what didn't). The claim that fabricating this number would be
   engagement-bait is correct per this codebase's stated product principle (see `HANDOFF.md`'s
   repeated "real data or nothing" framing echoed throughout this PR's comments). **Rule: skip is
   correct, not a dodge — the reasoning survives an adversarial check.**

### Cross-file / regression checks

- **Pre-existing `ReactionsRow` behavior for shipped types (`enforcement_active`,
  `sweeper_passed`) is unchanged.** Before this PR, `PinDetailSheet.ReactionsRow.body` was
  `if isOwnPin { deleteSection } else { voteSection }`. After: routes through
  `reactionsRowKind`, which for those two types (not own, not `leaving_soon`) still resolves to
  `.vote` → `voteSection`, the same function, unchanged. Verified with the `enforcement_active`-
  and `sweeper_passed`-flavored `reactionsRowKind` tests (existing-type regression tests,
  explicitly labeled as such in the test file). No behavior change for shipped enforcement/
  sweeper reactions.
- **Pre-existing gap correctly fixed, not introduced.** Before this PR, `PinDetailSheet.ReactionsRow`
  had *no* `leaving_soon` special case at all — a non-own `leaving_soon` pin (already
  `showsReactionsRow == true`, since it's crowd+ephemeral) fell into `voteSection`, i.e. it would
  have shown confirm/dispute buttons for a spot-handoff pin, which the spec never wanted. This
  PR's `.claim` case is a genuine fix of a latent Phase 1/2 gap in the detail sheet (the compact
  feed row already had the special case; the detail sheet didn't). Correctly not framed as a
  regression risk in the PR body, and it isn't one.
- **Both surfaces verified to call the shared function** (the PR #95 lesson): grepped both
  `PinDetailSheet.swift`'s `ReactionsRow.body` and `CrewFeedSection.swift`'s `PinFeedRow.actionRow`
  — both switch over `pin.reactionsRowKind(currentUserId:)`, no independent re-derivation of the
  branching logic remains in either file.
- **`claim_pin` RPC shape matches the applied schema exactly.** `supabase/03-community-2.0-schema.sql:582`:
  `claim_pin(p_pin_id uuid) returns boolean`. iOS payload: `["p_pin_id": pinId.uuidString]`,
  request path `rest/v1/rpc/claim_pin`, `Authorization: Bearer <jwt>` via
  `buildAuthenticatedRequest`, response decoded as a bare `Bool` (matches PostgREST's scalar-RPC
  response shape, not an array/row). `false` routes to a dedicated `claimMessage` state, never
  `errorMessage` — correctly never styled as a failure. No optimistic double-claim path (button
  `.disabled(isLoading)` on both surfaces).
- **S4 stub fully removed.** Grepped for "Coming soon" and the old `TODO(Phase 3, spec §2.10/§3):
  wire to claim_pin` comment — both gone from the PR's version of `CrewFeedSection.swift`; only a
  historical doc-comment reference to "was a disabled 'Coming soon' stub through Phase 1" remains,
  which is expected/fine (not a stray TODO).
- **Zone filtering consistency (feed vs. leaderboard) — verified consistent, not a bug.** The
  feed filters via `CrewFeedMerge.resolvedZoneId(for:)` = `pin.zoneId ?? CommunityZoneBounds.zoneId(forLat:lng:)`.
  The leaderboard filters via a server-side lat/lng box query using `CommunityZoneBounds.box(for:)`
  — the same static box table, just applied at the SQL layer instead of client-side. Since the
  only current insert call site (`ReportSheet.swift`) always passes `zoneId: nil`, every pin's
  stamped `zone_id` (via `CommunityPinService.resolveZoneId`) is itself derived from that same
  `CommunityZoneBounds` box lookup at insert time — so feed and leaderboard agree by construction
  for both zone-stamped and legacy nil-zone rows. The only way these could diverge is if
  `CommunityZoneBounds`'s box constants are edited without a matching DB re-seed, which the file's
  own doc comment already flags as a drift risk. Not a new bug, no action needed beyond what's
  already documented.
- **`makeDateDecodingJSONDecoder` factoring is behavior-identical.** The extracted function's body
  is a verbatim move of the ISO8601-with/without-fractional-seconds custom strategy previously
  inlined in `decodeResponse`; `fetchOwnProfile` and `fetchLeaderboardPins` (via `decodeResponse`)
  both now use it. `ZoneMessageService.swift` (the bigserial-id message model) is untouched by this
  PR — not in the file list, confirmed via `git diff --stat` — so the "ZoneMessage bigserial-id
  nuance" is unaffected by construction, not just by inspection.
- **RLS check.** `fetchOwnProfile` sends only an `apikey` header (no JWT) — correct, since
  `01-mvp-schema.sql`'s `profiles_select_all` policy is a public `select` (`using (true)`,
  confirmed present). `fetchLeaderboardPins` similarly anon-readable via `pins_with_author`'s
  `grant select ... to anon, authenticated` (`02-pins-schema.sql:282`, re-granted in
  `03-community-2.0-schema.sql`). Both match the codebase's existing "profiles/pins are public
  read, only writes are gated" posture.
- **Curb-legality palette untouched.** `Services/ParkingColors.swift` not in the diff. The hex
  values used in `CrewFeedMerge`/profile-row rep badge (`0x30D158`, etc.) are the pre-existing
  §6-appendix design colors already used for `sweeperPassed`'s icon in this same file since Phase 1
  — not a new color introduced into the curb-color family.
- **Copy audit.** Grepped `CrewFeedSection.swift` + `PinDetailSheet.swift` for "avoid", "ticket",
  "fine", "evasion", "dodge" (case-insensitive) — zero user-facing hits. The only "ticket"-adjacent
  text is a doc comment explaining why the tickets-dodged stat was skipped, not shipped copy.

### Tests (Pass 1)

35 new tests read in full (`WeParkTests/CommunityPhase3TrustLoopTests.swift`). Assessment:
behavior-asserting throughout, not shape-checking placeholders.

- `ReactionsRowKind` routing (7): covers both existing-type regression (`enforcement_active`,
  `sweeper_passed` via `nilCurrentUserId` case) and the new-type/own-pin matrix. Good — explicitly
  labeled "existing-type regression."
- `claimPin` (5): request-shape test (`testClaimPin_requestUsesRpcPathAndPinIdPayload`) actually
  inspects the captured `URLRequest`'s path and decodes the JSON body to check the `p_pin_id` key
  — not a stub. `false`-doesn't-throw and `noAuth`-throws are both exercised.
  `testClaimPin_falseResponse_returnsFalse_doesNotThrow` is exactly the right assertion for the
  race-safe-outcome requirement.
- `fetchOwnProfile`/`fetchLeaderboardPins` (5): `testFetchLeaderboardPins_queryIncludesSourceConfirmCountAndWindow`
  inspects the actual captured URL string for `source=eq.crowd`, `confirm_count=gt.0`,
  `created_at=gte.`, and *also* asserts the negative (`expires_at`/`resolved_at` are absent) — a
  real request-shape test, not just presence-checking. `unknownZone_returnsEmptyWithoutNetworkCall`
  correctly asserts `callCount == 0`, verifying the short-circuit is a true short-circuit and not
  just a documented intent.
- `accuracyLabel` (4) / `tenure` (5): boundary-complete for the stated AC (0/0, 0/5, 5/5,
  rounding; <1wk, 2wk, 1mo singular, 6mo, 2yr).
- `CommunityLeaderboard.build` (9): **tie-break is genuinely tested**
  (`testLeaderboard_tiesBrokenByUsernameAscending`, asserts `["Alice", "Zeke"]` ordering from
  input order `[Zeke, Alice]` — a real behavioral assertion, not a trivial pass). Top-5 cap,
  nil-author exclusion, no-duplicate-You-row, real-rank-below-top-5, honest-zero-rank, and
  empty-pins-still-gets-a-You-row are all covered. No test exercises the race condition in
  Finding #1 (that's a `CrewFeedSection` view-level async-orchestration bug, not something
  `CommunityLeaderboard.build`'s pure-function tests could catch — the gap is structural, not a
  missing-test-case problem).

Suite count: stated 1067 → 1102 (+35), matches the orchestrator's independently-verified static
count.

### Smoke tests run (Pass 1)

No live-simulator build/launch was performed for this pass — correctly out of scope for this PR
class. Verified instead:

- Read the full diff (`git diff main...480901ed`) file by file via `git show 480901ed:<path>`
  (not the local worktree checkout, which is on a different branch/commit — caught and corrected
  a self-inflicted process error early in this pass where an initial `grep`/`Read` against the
  worktree's on-disk files was silently reading stale pre-PR content).
- Read `PinMarkerAnnotation.swift`, `PinDetailSheet.swift`, `CrewFeedSection.swift`,
  `CommunityPinService.swift`, `CommunityZoneBounds.swift`, and the full 656-line test file at the
  PR's actual commit.
- Cross-referenced `supabase/03-community-2.0-schema.sql` (the applied migration) for `claim_pin`'s
  real signature, `profiles`/`pins_with_author` RLS/grants, and the `pins_with_author` column list
  (to verify the avatar-gap claim).
- Cross-referenced `design/prototype.html` lines 155-215, 320-335, 935-948 for the profile row,
  leaderboard, and claim-copy source values.
- Confirmed via `git diff --stat` that `ContentView.swift`, `BrowseNavigationSheet.swift`,
  `MapViewRepresentable.swift`, `ParkedCarDetailView.swift` are untouched — the PR's own claim
  that the mount-chain smoke gate doesn't strictly apply is correct, independently verified, not
  taken on faith.
- Did **not** run `xcodebuild` (Linux VPS, no toolchain, matches every prior Community 2.0 PR's
  posture) — compile/test execution is Kevin's Mac gate, per below.

### What's working (Pass 1)

- The `reactionsRowKind` unification is a genuinely good fix, not just a refactor — it closes a
  real, pre-existing gap (leaving_soon showing vote buttons in the detail sheet) while also
  guaranteeing the two surfaces can't drift apart in the future, which is exactly the discipline
  the PR #95 lesson asked for.
- The three disclosed deviations are all correctly reasoned and each is backed by an actual grep/
  verification claim in the code comments, not asserted from memory — I independently re-verified
  all three against the applied schema and found the reasoning holds.
- The "tickets dodged" skip is the right call, and flagging it explicitly in-code instead of
  silently omitting it is exactly the kind of honesty this codebase has been building toward.
- Test discipline is strong: request-shape tests genuinely inspect URL/body rather than trusting
  the implementation, and the tie-break test is a real behavioral assertion.
- `claim_pin`'s race-safety is correctly not treated as an error state anywhere in the UI, matching
  the spec's explicit framing.
- Nothing in this PR touches RLS, schema, or any file outside the stated Phase 3 surface — a clean,
  disjoint diff against a well-understood file set.

---

## Pass 2 — verification of the fix commit `e9fb9e8c`

Read cold via `git show e9fb9e8c:<path>` (learned my own Pass 1 lesson — did not trust the
worktree's on-disk checkout, which is still on `main`). Diffed `480901ed..e9fb9e8c` file by file.

### Finding #1 (leaderboard zone-switch race) — VERIFIED FIXED

- **`.task(id: selectedZone)` genuinely replaces the manual `Task`/`onChange` orchestration.**
  Grepped the fixed `CrewFeedSection.swift` for `Task {` — the only remaining manual `Task {}`
  call sites are the three user-action button handlers (`handleStillThere`, `handleGone`,
  `handleClaim`), which are correctly still manual (they're tap-triggered, not
  zone-switch-triggered — not leftovers). `body`'s `.onAppear`/`.onChange(of: selectedZone)` now
  only call the synchronous `selectZone(_:)` (sets the two services' zone filters); the async
  profile+leaderboard load moved entirely into `.task(id: selectedZone) { await
  loadProfileIfNeeded(); await loadLeaderboard(zone: selectedZone) }`.
- **`.task(id:)` fires on first appear.** Confirmed this is standard, documented SwiftUI
  behavior (`.task(id:)` runs its closure when the view first appears, in addition to re-running
  on every `id` change) — the leaderboard still loads on initial mount; nothing regressed here.
- **`loadLeaderboard` clears entries BEFORE the await, not after failure.** Verified:
  `leaderboardEntries = []` is the *first* statement in the function body, executed
  synchronously before `await pinService.fetchLeaderboardPins(...)`. The old "keep stale data on
  failure" doc comment is gone, replaced with an explicit note that an empty leaderboard section
  is now the deliberate "loading or failed" state.
- **`LeaderboardPublishGuard.shouldPublish` semantics correct for all 4 combinations, and it's
  load-bearing, not decorative.** `shouldPublish(fetchedZone:currentZone:isCancelled:) = !isCancelled
  && fetchedZone == currentZone`. Verified at the actual publish site:
  ```swift
  guard LeaderboardPublishGuard.shouldPublish(
      fetchedZone: zone, currentZone: selectedZone, isCancelled: Task.isCancelled
  ) else { return }
  leaderboardEntries = built
  ```
  This directly gates the state write — not a logged/asserted-only check. `currentZone:
  selectedZone` reads the view's live `@State` at call time (SwiftUI's `@State` storage is a
  stable box independent of the struct's value-type re-creation, so this correctly reflects the
  zone at publish time, not a value captured at fetch-start). `Task.isCancelled` reflects the
  enclosing `.task(id:)` task's cancellation state, since `loadLeaderboard` runs as a direct
  `await` within that task's closure, not a detached/unstructured child.
- **Adversarial interleaving traced: zone A slow → user switches to B → B publishes → A
  completes late.** Two independent layers both block A's stale write, so it can't land under
  any interleaving:
  1. When `selectedZone` changes from A to B, SwiftUI cancels A's `.task(id:)` task. Swift's
     `URLSession.data(for:)` async bridge is cancellation-aware and throws when its enclosing
     `Task` is cancelled — so A's in-flight `fetchLeaderboardPins` call is very likely to throw
     before it ever returns data, and `try? await pinService.fetchLeaderboardPins(...)` turns
     that into `nil`, hitting `guard let pins = ... else { return }` — A's flow terminates
     *before* it ever reaches the publish guard.
  2. Even in the degenerate case where A's fetch somehow still returns data despite
     cancellation (e.g. a test double that ignores cancellation), the explicit guard at the
     publish site catches it two ways: `Task.isCancelled` is true for A's own task (cancelled by
     the id change), OR even if that flag somehow lagged, `fetchedZone` (A) `!= currentZone`
     (B, the live `selectedZone` by the time A's `await` resumes) — either condition alone fails
     `shouldPublish`. A's rows cannot land under any ordering.
  - This is genuinely defense-in-depth, not redundant boilerplate: it protects against exactly
    the case its own doc comment names — a request that got cancelled but had already returned
    data microseconds before the cancellation flag propagated.
- **Tests (4, `LeaderboardPublishGuardTests`) cover the full truth table**, not just the happy
  path: `(same zone, not cancelled) → true`; `(zone changed, not cancelled) → false` (the exact
  Finding #1 scenario, explicitly commented as such); `(same zone, cancelled) → false`;
  `(zone changed, cancelled) → false`. All 4 logical combinations of the two boolean-ish inputs
  are exercised.

**Verdict: Finding #1 is correctly and robustly fixed**, with a genuine understanding of why the
explicit guard is needed on top of `.task(id:)`'s own cancellation (not just cargo-culted).

### Finding #2 (unbounded leaderboard query) — VERIFIED FIXED

- `buildLeaderboardRequest` now appends `URLQueryItem(name: "order", value: "confirm_count.desc")`
  and `URLQueryItem(name: "limit", value: "200")` to the existing filter set. Confirmed present
  in the actual request-building code, not just mentioned in a comment.
- **Test inspects the built request directly**: `testFetchLeaderboardPins_queryIncludesOrderAndLimit`
  captures the real `URLRequest.url` and asserts `url.contains("order=confirm_count.desc")` and
  `url.contains("limit=200")` — a genuine request-shape assertion, not a stub.
- **Top-5-over-top-200 semantic is honestly documented in two places**, not just tucked into a
  commit message: `CommunityLeaderboard.build`'s doc comment now explicitly states that for a
  zone with >200 qualifying pins/week, an author with many lower-confirm-count pins could rank
  slightly lower than an unbounded scan would show, and `buildLeaderboardRequest`'s own comment
  explains why 200 rows ordered by `confirm_count.desc` keeps the truncation biased toward the
  most-relevant rows rather than an arbitrary slice.
- **Ranking code makes no completeness assumption.** Read `CommunityLeaderboard.build` again at
  `e9fb9e8c` — unchanged from Pass 1 except the doc comment; it purely groups/counts/ranks
  whatever `pins` array it's handed, with no logic anywhere that assumes it has seen every
  qualifying pin in the zone (no total-count cross-check, no "did I get everything" branch).
  Correct: the query-level bound and the pure ranking function are cleanly separated, exactly as
  the fix's own comment claims.

**Verdict: Finding #2 is correctly fixed, with the accepted-tradeoff semantics documented
honestly rather than silently.**

### Finding #3 / #4 (claim copy) — VERIFIED FIXED

- New shared, pure `CommunityPin.claimStatusCopy(currentUserId:) -> String?`
  (`PinMarkerAnnotation.swift`): `nil` when unclaimed; `"You're heading there — first come, first
  served"` when `claimedBy == currentUserId`; `"Someone's heading there — first come, first
  served"` otherwise. Matches `prototype.html:207`'s `claimedTag`/`claimable` distinction.
- **Both surfaces call it.** Grepped both files: `PinDetailSheet.swift`'s `ReactionsRow.claimSection`
  and `CrewFeedSection.swift`'s `PinFeedRow.leavingSoonAction` both now do
  `if let statusCopy = pin.claimStatusCopy(currentUserId: authService.currentUserId) { Text/Label(statusCopy) }`
  — no independent re-derivation, same discipline as `reactionsRowKind`.
- **`currentUserId == nil` case:** `claimedBy == currentUserId` compares a non-optional `UUID`
  (unwrapped via `guard let claimedBy`) against `UUID?` via Swift's standard `Optional`
  promotion — when `currentUserId` is `nil`, this is always `false`, so the function safely falls
  through to the generic "Someone's heading there" copy. Explicitly tested
  (`testClaimStatusCopy_claimedByOther_nilCurrentUser_returnsSomeonesHeadingThere`).
- **Anonymous user who claimed:** an anonymous session still has a real `auth.uid()` from
  Supabase's anonymous auth, which is exactly what gets written to `claimed_by` and exactly what
  `authService.currentUserId` returns — there is no separate "anonymous" branch anywhere in this
  logic. An anonymous claimant correctly sees "You're heading there," same as a
  handle-picking user. Verified via `testClaimStatusCopy_claimedByCurrentUser_returnsYoureHeadingThere`,
  which doesn't distinguish handle-vs-anonymous because the underlying model doesn't either — the
  right behavior for the right reason.
- **Error strings unified.** Both `ReactionsRow.handleClaim` and `PinFeedRow.handleClaim` now
  read `"Couldn't claim — try again."` verbatim.

**Verdict: Finding #3 and #4 are both correctly fixed**, including the specific edge cases
(`nil` currentUserId, anonymous claimant) the coordinator flagged for adversarial checking.

### New tests (9) — assessment

`git grep -c "func test" e9fb9e8c -- ios/WePark/WeParkTests` sums to **1111** — matches
1102 (Pass 1) + 9 (Pass 2) exactly, independently verified via `git grep`, not taken from the
commit message.

- `ClaimStatusCopyTests` (4): unclaimed→nil, own-claim→"You're heading there", other's
  claim→"Someone's heading there", other's claim with `nil` currentUserId→"Someone's heading
  there". All four are genuine behavioral assertions against the real function, covering exactly
  the edge cases (nil-user, anonymous-claimant-is-just-a-UUID) the coordinator asked about.
- `testFetchLeaderboardPins_queryIncludesOrderAndLimit` (1): inspects the real captured URL for
  both new query params — a real request-shape test.
- `LeaderboardPublishGuardTests` (4): full truth table over `(fetchedZone == currentZone,
  isCancelled)`, including the exact Finding #1 scenario (`zoneChangedSinceFetchStarted →
  false`) called out by name in a doc comment. This is the strongest evidence that the fix's
  author understood *why* the guard exists, not just that a QA finding demanded one.

All 9 are behavior-asserting; none are shape-only/placeholder tests. The adversarial case
(zone-changed-since-fetch-started) is directly covered, not just implied by the happy-path test.

### New observation — leaderboard flash on every zone switch (not a defect, logging per instruction)

`loadLeaderboard` now unconditionally clears `leaderboardEntries` to `[]` **before** the await,
on *every* invocation of `.task(id: selectedZone)` — including switching back to a zone whose
data was already fetched and rendered a moment ago (there is no per-zone cache; each switch is a
fresh clear-then-refetch). Combined with `leaderboardSection`'s `if !leaderboardEntries.isEmpty`
guard, this means the "THIS WEEK" card visibly disappears and reappears on **every** zone chip
tap, even round-trips (Nolita → SoHo → Nolita), not just switches to never-before-seen zones.

This is a real, easily-observable UI side effect, but I'm not logging it as a new finding:
correctness-over-smoothness is the right call for a v1 fix to a data-integrity finding, the flash
is brief (bounded by the fetch latency, typically sub-second), and building a proper per-zone
cache with staleness tracking is a legitimate but separate polish task, not something this fix
needed to solve to close Finding #1. Recommend a `docs/community-2.0-roadmap.md` one-liner if a
future pass wants to smooth this (e.g. keep the OLD zone's entries visible with reduced opacity
until the new zone's fetch resolves, rather than clearing to empty) — not blocking anything today.

### Pass 2 smoke tests run

- `git fetch origin` + `git show e9fb9e8c:<path>` for all 5 changed files (not the worktree
  checkout, which remains on `main` — applied my own Pass 1 lesson from the start this time).
- `git diff 480901ed..e9fb9e8c` read in full, file by file, for all 5 changed files.
- `git grep -c "func test" e9fb9e8c -- ios/WePark/WeParkTests` to independently verify the 1111
  count rather than trusting the fix commit's message.
- Manually traced the adversarial slow-A/fast-B/late-A interleaving against both the
  cancellation-propagation behavior of Swift's `URLSession` async bridge and the explicit
  `LeaderboardPublishGuard` check, per the coordinator's specific instruction — not just read the
  code and asserted it "looks right."
- Did not re-run `xcodebuild` (still a Linux VPS, no toolchain) — unchanged posture from Pass 1.

## Kevin's gate (right-sized for this PR class — unchanged in shape from Pass 1, count updated)

This PR does not touch `MapViewRepresentable.swift`, `ContentView.swift`, any
`Views/DriveMode*.swift`, or any `.safeAreaInset`/overlay-attachment code — the mount-chain live-UI
smoke gate does not apply. Recommended gate:

1. **Mac toolchain gate (required):** `xcodebuild build` then `xcodebuild test` on
   `ios/WePark/WePark.xcodeproj` — this PR is `[COMPILE-UNVERIFIED]` like every prior Community 2.0
   PR; confirm **1111/1111** passes (updated from Pass 1's 1102 — verify the 9 new
   `ClaimStatusCopyTests`/`LeaderboardPublishGuardTests`/bounded-query tests compile and pass
   cleanly, since none of this has ever touched a real Swift compiler).
2. **Targeted flag-on visual check (recommended, not blocking):** with `communityEnabled = true`
   and a seeded profile, pull `BrowseNavigationSheet` to its `.large` detent and visually confirm
   the profile row + "THIS WEEK" leaderboard render as expected against
   `design/screenshots/05-feed-full.png`. While there, also just look at the leaderboard-flash
   behavior noted above (tap between zone chips) — purely to confirm it's the brief, acceptable
   flash this pass describes and not something worse in practice.
3. **Two specific interaction live-tests (recommended before flipping `communityEnabled` on for
   testers, not before merge):**
   - **Claim race + own-claim copy:** two anonymous sessions both tap "I'm heading there" on the
     same `leaving_soon` pin — confirm the second gets "someone beat you to it," and confirm the
     *first* (winning) session now shows "You're heading there" once Realtime catches up, not the
     old generic "someone's heading there" copy.
   - **Zone-switch leaderboard under bad network:** tap between zone chips with Network Link
     Conditioner set to "Very Bad Network" — confirm the leaderboard never shows a zone mismatch
     (this is now a genuinely hard bug to hit given the fix, but worth one real-device pass since
     it's the AC-P3.4 criterion that failed Pass 1).
4. No findings from either pass block merge as of Pass 2 — all four are fixed and verified. The
   only open item is the out-of-scope leaderboard-avatars follow-up ticket (§ "Out of scope"
   above), which doesn't block this PR.
