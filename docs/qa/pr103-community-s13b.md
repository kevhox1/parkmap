# Community 2.0 S13b QA Pass 1 — 2026-09-06

**Reviewed:** branch `ios/community-s13b` at `2585ebab`, against `origin/main` (`2cd14f3f`),
`docs/design/community-2.0-hero-gap-inventory.md` WP3, `docs/community-2.0-roadmap.md` S13b row,
`design/prototype.html:218-279`/`:881`, `design/screenshots/07-block-detail.png` (visual reference
only — no live render performed, see Smoke tests run), `supabase/01-mvp-schema.sql`,
`supabase/03-community-2.0-schema.sql`.

**Verdict: MERGE-AFTER-MAC-GATE.** The write path is correctly built against the live schema and
the RLS verdict in the PR's own header is independently confirmed correct. The identity-gate
pattern, flag-off byte-identity, and shared-logic-reuse claims all check out against the actual
call sites, not just the doc comments. Two 🟡 findings (no live realtime for the block-chatter
thread while the sheet is open; no test for the 1000-char body ceiling) are real but neither is
disqualifying — they're follow-up-bug-shaped, not "the feature is broken" shaped. This PR has not
been compiled, built, or visually rendered (Linux VPS, no Xcode) — Kevin's Mac gate below is
mandatory before merge, not a formality.

## Acceptance criteria checklist (WP3 / S13b row)

- [x] `ZoneMessageService.sendMessage` inserts a `zone_messages` row with the correct column set
  (`zone_id`, `author_id`, `message_type`, `body`, optional `segment_id`) — verified by reading
  `sendMessage` against `01-mvp-schema.sql:72-97` + `03-community-2.0-schema.sql:146-151`.
- [x] `author_id` is both client-sent (the authenticated user's own uid) AND independently
  RLS-checked (`author_id = auth.uid()`) — verified in `ZoneMessageService.swift:512-517` vs.
  `zone_messages_insert_user` (`01-mvp-schema.sql:91-97`). A spoofed `author_id` would 42501, not
  silently succeed.
- [x] Body length enforced client-side against the real CHECK constraint
  (`length(body) between 1 and 1000`) — `ZoneMessageService.bodyMaxLength = 1000`, verified
  verbatim against `01-mvp-schema.sql:77`.
- [x] Empty / whitespace-only send prevented — both `ZoneMessageComposeLogic.canSend` (UI gate,
  disables the send button) and `sendMessage`'s own `guard !trimmed.isEmpty` (network-call gate)
  reject it; tested (`ZoneMessageComposeLogicTests`, `testSendMessage_emptyBody_throwsInvalidBody_noNetworkCall`).
- [x] `return=representation` is safe on this table — independently re-derived from
  `zone_messages_select_all` `using (true)` (`01-mvp-schema.sql:88-89`): the S11 RETURNING trap
  (narrow SELECT policy under a wide INSERT policy) genuinely does not apply here. Confirmed, not
  just trusted.
- [x] `award_chat_reputation` fires server-side only, client payload never touches reputation —
  verified against `03-community-2.0-schema.sql:327-341`; `sendMessage`'s payload has no
  reputation-shaped field.
- [x] Identity-gate deviation (nested sheet-on-sheet, not `ActiveSheet.identityPrompt`) matches
  the established `ReportSheet`/`ParkedCarDetailView` precedent byte-for-byte — verified by
  diffing all three call sites' `pendingIdentityAction`/`identitySheetPresented` shape.
- [x] Show-once semantics preserved — `IdentitySheet.onAppear` calls `CommunityIdentityGate().markShown()`
  itself (`IdentitySheet.swift:227-233`), so BlockDetailView/CrewFeedSection inherit this for free;
  not re-implemented, not forked.
- [x] Swipe-dismiss cancels the send without posting — the `.sheet(isPresented:)` binding's `set`
  closure nils `pendingIdentityAction` on any dismissal path (including swipe), and
  `pendingIdentityAction` is the only thing that invokes the deferred send; verified by trace, not
  by test (no XCUITest in this repo's suite for this).
- [x] Flag-off byte-identical — every new BlockDetailView section (swept badge, LIVE ON THIS
  BLOCK, BLOCK CHATTER) is gated on `AppConstants.communityEnabled`; the identity-sheet modifier
  itself only ever presents via state that only new, flag-gated code paths can set.
- [x] Color header / severity band reads current state via the SAME derivation as the rest of the
  app — verified this code is **untouched** by the diff (`engine.currentStateColor(for:at:)`,
  pre-existing) — not a fork, because it was never touched.
- [x] Big status line reuses existing derivation, no fork — both `BlockDetailView.safetyLabelView`
  and `ParkedCarDetailView.safetyLabelView(for:)` call `engine.safetyLabel(for:at:).text` directly;
  verified by grep, both call sites confirmed, neither pre-existing nor new code re-derives it.
- [x] Swept badge decision logic reused (not forked) — `ParkedCarDetailLogic.liveSweeperPin`/
  `confirmCountLabel` called directly by both files. **View-layer badge composition (color
  literal, Text/Capsule styling) IS duplicated** between the two files, byte-identical today —
  flagged as a drift-risk note, not a defect (see Findings, 🟢).
- [x] "LIVE ON THIS BLOCK" routes through the shared `reactionsRowKind(currentUserId:)` — verified
  by grep: `PinFeedRow` (widened `private`→`internal` this session) is the SAME type
  `PinDetailSheet.swift`'s reactions row already routes through this function; `BlockDetailView`
  reuses that type directly, not a copy.
- [x] Block chatter is block-anchored, zone-wide (`segment_id IS NULL`) messages excluded —
  `fetchMessages(segmentId:)` filters `segment_id=eq.<id>`; standard SQL three-valued logic means
  a `NULL` `segment_id` row never matches an `eq.` filter. Confirmed by reading the PostgREST
  query builder, not assumed.
- [x] Copy verbatim: empty-chatter state (`design/prototype.html:881`: "Be the first — crews form
  block by block.") and section headers ("LIVE ON THIS BLOCK", "BLOCK CHATTER") and compose
  placeholders ("Message this block…", "Say something to the square…") all match character-for-
  character against `prototype.html`.
- [ ] Realtime: sent messages from OTHER users appear in an already-open BlockDetailView without a
  manual refresh — **NOT satisfied**. See Finding #1 (🟡).
- [ ] `sendMessage`'s 1000-char ceiling is exercised by a test — **NOT satisfied**, logic is
  correct but untested at the boundary. See Finding #2 (🟡).

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: BlockDetailView's "BLOCK CHATTER" thread has no live update path — messages from other
  users never appear while the sheet stays open, only a one-shot fetch on mount.**
  - Where: `Views/BlockDetailView.swift` — `blockChatterSection`'s `.task { await loadChat() }`
    is the ONLY read; `chatMessages` is local `@State`, never wired to
    `ZoneMessageService.messages`/its Realtime channel (`handleRealtimeInsert`, which gates on
    `selectedZoneId` — a dimension `BlockDetailView` never sets or reads).
  - What: The service-level Realtime subscription for `zone_messages` (started/stopped by
    `ContentView` at `ContentView.swift:3212/3287/3314`) exists and fires inserts, but
    `BlockDetailView` has no subscription of its own and doesn't observe the shared service's
    published `messages` array (by design — it's block-scoped, the shared array is zone-scoped).
    Your OWN sent message appends optimistically (`performSendChat`'s `chatMessages.append(sent)`)
    — that part matches the prototype's "immediate append" behavior — but a neighbor posting to
    the same block 10 seconds after you open the sheet will not show up until you close and
    reopen it.
  - Expected: The prototype's model is a live, continuously-updated array (`S.chats`); nothing in
    the prototype models a stale one-shot fetch.
  - Repro: Open BlockDetailView for a segment, have a second (or seeded/SQL) user insert a
    `zone_messages` row with that `segment_id` while the sheet stays open — the new row never
    appears without dismissing and reopening the sheet.
  - Judgment: acceptable for an MVP write-path session (this is a short-lived sheet, not a
    persistent chat surface) but is a real, named gap against "does it appear without refetch,"
    not a nitpick. Log as a fast-follow rather than block on it — it doesn't reduce the value of
    the WP3 headline (write path + `award_chat_reputation` reachability), and building it now
    would require either a second live channel keyed by `segment_id` or teaching the existing
    zone-scoped channel a second filter dimension, either of which is a bigger, more contention-
    prone change to `ZoneMessageService.swift` than this session's stated scope.
  - Owner: `@ios-engineer` (fast-follow, not blocking S13b).

- **#2: No test exercises `sendMessage`'s 1000-character body ceiling.**
  - Where: `ZoneMessageWritePathTests.swift` — `SendMessageValidationTests` only covers the
    whitespace-only / empty-body case (`testSendMessage_emptyBody_throwsInvalidBody_noNetworkCall`).
    No test constructs a >1000-char draft and asserts `.invalidBody` + `networkCalled == false`.
  - What: The logic itself (`trimmed.count <= Self.bodyMaxLength`) is simple and, on inspection,
    correct — but it's the exact kind of off-by-one/boundary logic ("<=" vs "<") that this
    codebase's own testing convention (every other boundary check in this session IS tested, e.g.
    `showsEmptyChatterState`'s loading/empty boundary) says should have a test.
  - Expected: A test asserting a 1001-char draft throws `.invalidBody` without a network call,
    and (ideally) a 1000-char-exact draft succeeds (fencepost).
  - Repro: N/A (missing coverage, not a live bug) — I read the guard clause; `trimmed.count <= 1000`
    is correct as written.
  - Owner: `@ios-engineer`.

### 🟢 Minor / nit

- **#3: Swept badge is view-layer-duplicated, not shared, between `BlockDetailView` and
  `ParkedCarDetailView`.** Byte-identical today (same color literal `Color(red: 48/255, green:
  209/255, blue: 88/255)`, same copy format, same accessibility label) — confirmed by diffing both
  files. This is the PR's own documented, deliberate choice (matches the established
  `RuleRow.formatMinutes` duplication precedent already in this codebase), not an oversight. Flag
  only so a future edit to one badge's copy/color doesn't silently miss the other — no action
  needed now.
- **#4: `String.count` (Swift grapheme clusters) vs. Postgres `length()` (Unicode codepoints) can
  disagree for combining-character/ZWJ-emoji-heavy messages** (e.g. a family emoji sequence is 1
  Swift grapheme cluster but multiple Postgres "characters"). At the extreme edge, a message the
  client accepts as ≤1000 could still 400 server-side, or vice versa. Vanishingly unlikely to
  matter for a parking-chat body, not worth a special case pre-launch.
- **#5: Double-send race is theoretically possible but matches established codebase convention.**
  `submitChat()`/`submitCrewMessage()` are synchronous; the `isSendingChat`/`isSendingCrewMessage`
  guard that disables the send button is only set `true` inside the awaited `Task {}` body, so a
  sub-frame double-tap before the Task's first suspension point could in principle slip two
  requests through. This is the exact same shape as `ReportSheet.submitReport()` and
  `ParkedCarDetailView.submitLeavingSoon()` already ship with — not a new risk this PR introduces,
  and not worth a special-case fix here in isolation from those two.

### 💡 Out of scope (logged, not fixed)

- The crew feed's zone-level compose bar posts to `selectedZone.id` (whichever zone is currently
  browsed via the zone chips), not a "home zone." This is NOT a regression — no "home zone" concept
  exists anywhere in the codebase today, so there is nothing else it could reasonably post to. The
  prototype's "you're browsing this square — posting stays in your home square" copy/behavior (gap-
  inventory row 6) was already explicitly flagged as an orphaned gap to fold into S13c's copy pass,
  not S13b's — correctly out of this PR's scope, restating it here only so it doesn't get
  rediscovered as a "new" bug later.
- `HANDOFF.md` shows a spurious 14-line deletion when diffing `origin/main` → `origin/ios/community-s13a`
  directly (S13a branched before the 2026-09-05 "THE BUZZ" changelog entry landed on main). Verified
  via an actual 3-way merge (`git merge`, not `git diff`) that the entry survives correctly in the
  merged tree — this is a diff-view artifact, not a real conflict or content loss. Unrelated to
  S13b itself; noted here only because it surfaced during the cross-branch check this dispatch
  asked for.

## Merge-order recommendation (s13a vs s13b)

Both PRs branched off `main` independently and both touch `ContentView.swift`, but at
**non-overlapping hunks** (s13a: lines ~314-339, ~1320-1340, ~1923-2172, ~2081-2140, ~2115-2130;
s13b: lines ~847-858, ~1725-1741 — nearest gap is ~180 lines). I tested both merge orders in a
scratch clone:

```
main → merge s13a → merge s13b   →  clean auto-merge, ContentView.swift resolves with no conflict markers
main → merge s13b → merge s13a   →  clean auto-merge, ContentView.swift resolves with no conflict markers
```

Both orders produce a tree with **1246 tests** (main 1183 + s13a's delta + s13b's 38), no duplicate
symbols, and the "THE BUZZ" changelog entry intact regardless of order. **No collision either
file (`ContentView.swift`) or direction requires manual resolution.** Recommend merging in the
order Kevin's Mac gates clear (S13a's own MERGE-AFTER-MAC-GATE verdict from PR #102 is unrelated
sequencing, not a technical dependency) — whichever gate clears first, merge first; the second
branch's rebase is mechanical.

`CrewFeedSection.swift` is touched only by S13b — zero collision risk there regardless of order.

## Kevin's gate (Mac, right-sized for this PR)

This PR does **not** touch `MapViewRepresentable.swift`, `ContentView`'s mount chain in a chrome-
overlay sense, `DriveMode*.swift`, or add a new `.safeAreaInset`/overlay layer — it's a sheet-
content redesign (`BlockDetailView`, already presented via `.sheet(item:)`) plus a compose bar
inside an already-mounted section (`CrewFeedSection`). It does NOT meet this repo's hard "live-
UI-smoke mandatory" bar the way a mount-chain PR does, but it is a high-traffic, tap-a-curb-line
surface with a real write path against prod — a build+test pass alone is not enough for sign-off
here either. Right-sized gate:

1. **`xcodebuild build` + `xcodebuild test`**, flag OFF (default) — must be green, all ~1221
   (post s13a-merge: ~1246) tests passing, zero new compiler warnings in the touched files.
2. **`xcodebuild test` with `AppConstants.communityEnabled = true`** — confirm the flag-flip
   prerequisite noted in the roadmap (3 known flag-on failures as of 2026-08-28) hasn't grown a
   4th from this PR; if all 3 are pre-existing and unrelated to S13b's files, that's fine, just
   confirm no *new* flag-on failure.
3. **Tap a curb line → BlockDetailView, flag ON.** Screenshot and eyeball: severity band color
   unchanged from pre-S13b baseline, swept badge (need a live `sweeper_passed` pin on that exact
   segment — seed one via SQL against a test zone if none exists naturally) renders with correct
   copy/color, "LIVE ON THIS BLOCK" section (seed a crowd pin on the same `segment_id`) renders and
   its confirm/dispute affordances work, "BLOCK CHATTER" renders the verbatim empty state when no
   messages exist for that block.
4. **Send a real chat message from the sim against prod Supabase.** Verify: (a) message appears in
   the UI immediately (optimistic append, no visible delay), (b) the row actually lands in
   `zone_messages` in the Supabase dashboard with the correct `zone_id`/`segment_id`/`author_id`,
   (c) `profiles.reputation` for that test account increments by exactly 1 (confirms
   `award_chat_reputation` fires and this is genuinely the first write path that reaches it).
5. **First-post identity gate, fresh device/simulator state.** Confirm the identity sheet appears
   before the first-ever chat send; swipe-dismiss it mid-flow and confirm (via the Supabase
   dashboard) that NO row was inserted for that attempt; re-tap send afterward and confirm it now
   posts anonymously (the `CommunityIdentityGate` "seen" flag latches on sheet appearance, not on
   completion — this is intentional per `IdentitySheet.swift`'s own header, just confirm it behaves
   that way live, not just in the tests).
6. **CrewFeedSection's zone-level compose bar** — same send-and-verify-in-dashboard check, confirm
   it lands with `segment_id: null` and appears in the crew feed instantly via the existing
   optimistic-append path (not a stale feed until next Realtime tick).
7. **Flag-off regression check** — flip `AppConstants.communityEnabled = false`, rebuild, confirm
   BlockDetailView renders byte-identically to the pre-S13b screenshot baseline (no swept badge, no
   LIVE ON THIS BLOCK, no BLOCK CHATTER, no compose bar) — this is the PR's own explicit claim and
   is cheap to falsify if wrong.

If steps 1-2 and 4-6 pass, ship. Step 3/7 visual eyeball is confirmatory, not a hard gate on its
own — this PR's risk is concentrated in the write path (steps 4-6), not the visual layout, since
the visual layout reuses `PinFeedRow`/severity-band/status-line code that's already shipped and
QA'd elsewhere.

## Smoke tests run

- **Read every changed line of the diff** (`ContentView.swift`, `ZoneMessageService.swift`,
  `BlockDetailView.swift`, `CrewFeedSection.swift`, both new test files) against the spec and the
  schema — not just the PR's own doc comments.
- **Independently re-derived the RLS/RETURNING verdict** from `01-mvp-schema.sql`'s actual policy
  text (`zone_messages_insert_user`, `zone_messages_select_all`) rather than trusting the PR
  header's claim — confirmed correct.
- **Verified `03-community-2.0-schema.sql` (the `segment_id` column + view recreation this PR's
  read/write path depends on) is already live in production**, per `HANDOFF.md`'s "Gate 1 — Phase
  0 schema LIVE IN PRODUCTION" entry — this PR is not silently depending on an unapplied migration.
- **Traced the "no fork" claims by grep/read, not by trusting comments**: `severityBand`
  (untouched), `safetyLabelView`/`safetyLabelView(for:)` (both call the same
  `engine.safetyLabel(for:at:)`), `PinFeedRow`'s `reactionsRowKind(currentUserId:)` routing (same
  function, same type, both `PinDetailSheet.swift` and the new `liveOnThisBlockSection` call site).
- **Verified copy verbatim** against `design/prototype.html` lines 218-279 and 881 for the empty-
  chatter state, section headers, and both compose-bar placeholders — character-for-character
  match including the em dash.
- **Cloned to a scratch directory and test-merged both orders** (`main→s13a→s13b` and
  `main→s13b→s13a`) to verify zero merge conflicts in `ContentView.swift` regardless of sequencing,
  and confirmed the resulting tree's test count (1246) and the previously-flagged spurious
  `HANDOFF.md` diff artifact resolves correctly under an actual 3-way merge.
- **Confirmed the static test count** (1221 on `ios/community-s13b`, 1183 on `main`, delta 38 —
  14 in `ZoneMessageWritePathTests.swift` + 24 in `BlockDetailS13bTests.swift`) by direct grep of
  both checked-out trees, not by trusting the PR description.
- **Did NOT build, compile, or run the app.** No Xcode/simulator on this Linux VPS. No live-UI
  screenshot was taken or inspected for this pass — see Kevin's gate above for what's required
  before merge.
- **Did NOT run a live network call against production Supabase.** The write path's correctness
  is verified by code/schema cross-reference only; the actual "does the row land, does reputation
  increment" behavior is unverified until Kevin's gate step 4.

## What's working

- The RLS/RETURNING analysis in `ZoneMessageService.swift`'s header is not just correct, it's
  **correctly derived from first principles** (compares this table's SELECT policy shape against
  the S11 incident's failure mode) rather than pattern-matched from the S11 postmortem without
  re-checking the premise — this is exactly the kind of "check before shipping a write that could
  42501" discipline the dispatch asked for, and it holds up under independent re-derivation.
- The identity-gate reuse is genuinely disciplined: three independent call sites
  (`ReportSheet`, `ParkedCarDetailView`, and now `BlockDetailView`/`CrewFeedSection`) share the
  exact same `pendingIdentityAction`/`identitySheetPresented` shape, and the "show once" latch
  lives in `IdentitySheet` itself rather than being re-implemented per call site — this makes it
  structurally impossible for one of the four call sites to silently drift on show-once semantics.
  This is the QA-cleared PR #96 pattern, applied correctly a third and fourth time.
- `PinFeedRow`'s `private`→`internal` widening for reuse (rather than a parallel duplicate type)
  is the right call and is exercised correctly — `BlockDetailView`'s "LIVE ON THIS BLOCK" section
  and the crew feed's own pin rows literally cannot disagree about confirm/dispute/claim behavior
  because they're the same compiled type calling the same routing function.
- Test discipline is strong for a COMPILE-UNVERIFIED PR: the wire-shape tests
  (`ZoneMessageWritePathTests`) individually assert URL, method, payload shape,
  segment_id-included-vs-omitted (not JSON `null`, a real PostgREST gotcha), trimming, and the
  exact `Prefer` header value — this is a well-targeted test suite for a network write path, not
  a rubber-stamp count.
- Flag-off parity is genuinely verifiable by inspection, not just claimed: every new visual
  section has its own `AppConstants.communityEnabled` gate, and the identity-sheet modifier's
  presentation state has no path to becoming true when the flag is off.
