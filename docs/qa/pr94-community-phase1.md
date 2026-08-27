# Community 2.0 Phase 1 (S3+S4) QA Pass 1 — 2026-08-27

**Reviewed:** branch `ios/community-phase1` @ `4034466b` (S4, on top of S3 `a232b75a`), against
`docs/community-2.0-reconciliation-spec.md` §3 Phase 1 + §6, `docs/ft20-bottom-sheet-navigation-spec.md`
§0f, and `design/prototype.html`. Diff base: `origin/main` @ `eb19b947`.
**Verdict:** 🔴 **FIX-THEN-MERGE** — two blocking findings, both fixable without a large rewrite.
Kevin's Mac live-sim smoke (AC-P1.5) is still mandatory before merge regardless of these findings,
and must specifically exercise the two scenarios below, not just the standard checklist already
planned in the PR body.

## Summary

This is careful, well-documented work — the model/service layer (S3) and the crew-feed UI (S4)
both read as if the authors actually understood the spec, not just pattern-matched it. The detent
reuse is the right call (see below), the copy audit is clean, the tests genuinely assert behavior
rather than just construct objects, and several deferrals are honestly flagged rather than silently
dropped. But two things are wrong at the architecture level, not the polish level: (1) the
`communityEnabled` dark-ship flag, which the PR's own code comment calls "the entire Community 2.0
layer," does not actually gate the map-marker/fetch path — any `open_spot`/`leaving_soon` row in
production `pins` would render to every user today, flag or no flag; and (2) the crew-feed slot's
`.frame(maxHeight: .infinity)` sibling, mounted unconditionally at `.large` regardless of the flag,
plausibly halves the space available to the pre-existing, heavily-used search suggestions/recents
`List` at that same detent — a real risk to a live, load-bearing feature, in exactly the "List-greedy-
sizing trap" bug class this file was already burned by once (FT-20 §0d finding C1). Both are
concrete, traceable in the diff, and neither requires reopening the phase's actual scope.

## Acceptance criteria checklist

- [x] AC-P1.1 (map-marker half) — ring marker + "P"/🚙 glyph, correct color, age-not-expiry
      subtitle: code-verified in `PinMarkerAnnotation.swift`. **Not live-verified** (no simulator
      access here); also see Finding #1 — the marker *will* render even with the flag off if a
      row exists, which is a bigger problem than "not yet verified live."
- [x] AC-P1.2 (partial, honestly flagged) — zone chips drive both services; empty-zone shows the
      intentional empty state. The map-region-fetch clause is explicitly out of scope this
      session, correctly documented. See Finding #3 for a related, unflagged gap (zone_id is
      `nil` on every pin any current write path produces, so the "feed" half of AC-P1.2 will show
      zero pre-existing crowd pins in practice, not just fewer than a moved map would produce).
- [ ] AC-P1.3 (pixel-identical resting sheet, flag off) — **peek/medium are untouched code,
      verified by diff** (no lines changed in either branch). But AC-P1.3's spirit ("zero
      regression to the shipped browse experience") is undermined by Finding #2, which changes
      `.large`'s layout even with the flag off. Not literally a peek/medium violation, but not the
      "genuinely nothing changed" bar this PR's own body claims either.
- [x] AC-P1.4 (intentional empty state) — `CrewFeedMerge.showsEmptyState` + `emptyStateView`,
      unit-tested, code matches design intent (not verbatim prototype copy, which spec §6 doesn't
      require for this string).
- [ ] AC-P1.5 (live-simulator smoke) — **not run**, correctly flagged as not run by the PR itself.
      Mandatory before merge. Must include the two scenarios in Findings #1 and #2 explicitly,
      not just the toolbar/ASP-banner/Park-Until-pill checklist already planned.

## Findings

### 🔴 Blocking

- **#1: The `communityEnabled` dark-ship flag doesn't gate the map-marker/fetch path — only the crew-feed UI and zone-chat realtime.**
  - Where: `Services/CommunityPinService.swift` (`buildCrowdEphemeralRequest`'s `pin_type` filter,
    `isChannel2Member`, `RealtimeMergeGate.mergeablePinTypes`), `ContentView.swift:2478`
    (`handleVisiblePinsChange`'s `mapMarkerTypes` set).
  - What: `Constants.swift`'s own doc comment for `communityEnabled` says: *"Dark-ship flag for the
    entire Community 2.0 layer (crew feed, zone chips, new report types, identity sheet, reactions
    extensions, push)... nothing reads this flag to change behavior until a consumer wires it up."*
    That's true for `ZoneMessageService`'s realtime lifecycle and `CrewFeedSection`'s mount (both
    correctly gated in `ContentView.swift` — only 6 hits for `communityEnabled` in the whole diff,
    all in `ContentView.swift`, all around the UI/realtime-lifecycle wiring). It is **not** true for
    `CommunityPinService`'s own fetch machinery: `grep communityEnabled` across
    `CommunityPinService.swift` and `RealtimeMergeGate.swift` returns **zero hits**. Channel 2's
    periodic/on-region-change fetch (`fetchPins` → `buildCrowdEphemeralRequest`, pre-existing,
    unconditional, no flag anywhere near it) now queries `pin_type=in.(enforcement_active,
    sweeper_passed,open_spot,leaving_soon)` regardless of the flag. `RealtimeMergeGate.mergeablePinTypes`
    and `ContentView`'s `mapMarkerTypes` are both widened as plain, unconditional `Set` literals.
  - Consequence: any `open_spot`/`leaving_soon` row that exists in production `pins` — from
    `supabase/03-community-2.0-test.sh`'s own test inserts (spec §2.13, this PR's diff touches that
    script), a future internal QA insert, or a cleanup failure mid-script — is fetched, passes the
    realtime merge gate, and renders as a live map marker to **every app instance**, TestFlight or
    production, flag on or off. Phase 0's migration is already applied to prod (`eb19b947`'s commit
    message: "Phase 0 live in prod"), so the enum values already exist server-side — this isn't a
    hypothetical future risk, it's live today.
  - Expected: per the flag's own doc comment and per spec §4 ("What's actually gated on Kevin's
    build-18 drive test... is turning `communityEnabled` on for external TestFlight testers" — the
    clear implication being nothing Community-2.0-shaped is visible before that flip), the entire
    marker-rendering/fetch path for the two new types should be a no-op while the flag is false.
  - Repro: insert one `open_spot` row into prod `pins` (exactly what `03-community-2.0-test.sh`
    already does, sans its own cleanup step) with `communityEnabled` at its shipped `false` — the
    marker renders on every user's map on the next 45s refresh or the next Realtime tick. No code
    change, no rebuild, no flag flip needed to trigger it.
  - Owner: `@ios-engineer` — add `guard AppConstants.communityEnabled else { return nil / [] }` (or
    equivalent) at `buildCrowdEphemeralRequest`'s pin_type list (fall back to the pre-Phase-1 two
    types) and at `mapMarkerTypes`/`mergeablePinTypes`'s widened entries, OR gate right at the
    filter/set construction site so the two new types are inert until the flag flips. Cheapest fix:
    keep the fetch query itself widened (harmless — an empty result set costs one extra `in.()`
    value) but gate the two `Set` memberships (`mapMarkerTypes`, `mergeablePinTypes`) behind the
    flag, matching the pattern already used for `zoneMessageService.startRealtime()`.

- **#2: The crew-feed slot's `.frame(maxHeight: .infinity)` sibling competes with the pre-existing search `List` at `.large`, even with the flag off.**
  - Where: `Views/BrowseNavigationSheet.swift`'s `body`, the new
    `if detentKind == .large { crewFeedBuilder().frame(maxHeight: .infinity) }` block (added after
    `actionColumn`).
  - What: Before this PR, `.large`'s `VStack(spacing: 0)` had exactly two children:
    `searchAreaBuilder(...)` (only a `.frame(minHeight:)` floor, no max — its internal content,
    `BrowseSearchAreaView.recentDestinationsList`/`suggestionsList`, is a UIKit-bridged `List`,
    which is unbounded-greedy by default) and, conditionally, `actionColumn` (a hard
    `.frame(height: actionColumnHeight)`). With only one unbounded-flexible child (`searchArea`),
    it received effectively all the VStack's leftover height after `actionColumn`'s fixed slice —
    this is the exact behavior FT-20's own QA history (`docs/ft20-bottom-sheet-navigation-spec.md`
    §0d, finding C1) already identified and worked around once for `actionColumn`, specifically
    because unconstrained `List`s inside this VStack are known to misbehave.
    This PR adds a **second** unbounded-flexible sibling — `crewFeedBuilder().frame(maxHeight:
    .infinity)` — after `actionColumn`. `ContentView.swift`'s `crewFeed:` closure is
    `{ if AppConstants.communityEnabled { CrewFeedSection(...) } }`; with the flag `false` this
    evaluates to `nil` (an `if`-with-no-`else` `@ViewBuilder` optional), but the `.frame(maxHeight:
    .infinity)` modifier is applied to that optional's *result*, not conditionally — the modified
    node still exists as a distinct VStack child and still asks for "as much height as the parent
    will give," the same layout signal a `Spacer()` sends, independent of whether its content is
    visually empty. SwiftUI's stack layout algorithm splits leftover space **among however many
    unbounded-flexible children exist**, not just the ones with visible content. Practically, this
    means the search suggestions/recents `List` — a shipped, constantly-used feature — likely now
    gets roughly half the vertical room it got before this PR, at `.large`, **regardless of the
    community flag's value.**
  - The PR body's own "Known interaction" note acknowledges the two features compete for space
    ("if both are on-screen at once... same as any two flexible VStack siblings") but frames it as
    only relevant once the crew feed has real content — it doesn't appear to have considered that
    the frame modifier claims the layout share whether or not the wrapped content is visually
    empty. That's a reasonable oversight to make from a Linux VPS with no way to render the tree,
    but it's exactly the class of bug this file's own history says can't be reasoned about from
    the source alone (six rounds of `BrowseSheetDetentMath` measurement bugs, all invisible until
    an actual device screenshot).
  - Expected: per AC-P1.3 (and the PR body's own claim, "byte-identical, not just visually
    identical"), `.large`'s pre-existing search/recents/suggestions behavior should be completely
    unaffected while the flag is off.
  - Repro (requires a device/simulator, cannot be done from this VPS): build with
    `communityEnabled = false` (shipped default), tap the search field to expand to `.large` with
    an empty query (shows `recentDestinationsList`), and visually compare the list's rendered
    height against a build from `origin/main` at the same detent. If the list is visibly shorter
    than before, this finding is confirmed.
  - Owner: `@ios-engineer` — either (a) don't apply `.frame(maxHeight: .infinity)` to the
    `crewFeed()` result when it's empty (harder to express cleanly with a generic `CrewFeed: View`
    parameter), or (b) constrain `searchArea` with an explicit `.frame(maxHeight:)` at `.large` so
    it isn't relying on being the sole unbounded-flexible sibling to get full height (more robust,
    also closes the door on any *future* third flexible sibling causing the same bug again), or
    (c) mount `crewFeedBuilder()` only when `AppConstants.communityEnabled` is true, inside
    `BrowseNavigationSheet` itself (not just in `ContentView`'s builder closure) — moving the flag
    check one level down so the VStack literally has one fewer child when the flag is off, rather
    than a child whose content happens to be empty.

### 🟡 Significant

- **#3: The crew feed's zone filter (`pin.zoneId == zoneId`, strict equality) will show zero
  pre-existing crowd pins for any zone, because no current write path ever sets `zone_id`.**
  - Where: `Views/CrewFeedSection.swift`'s `CrewFeedMerge.merge` (`pins.filter { $0.zoneId ==
    zoneId }`); `Views/ReportSheet.swift:541` (`zoneId: nil`, the only iOS write path that inserts
    `enforcement_active`/`sweeper_passed` today).
  - What: `RealtimeMergeGate.isInZone` and `CrewFeedMerge.merge` are both, by design and by test
    (`testMerge_pinWithNilZone_excludedUnderAnySelectedZone`, `testIsInZone_pinZoneNil_
    selectedZoneActive_excluded`), strict: a pin with `zone_id == nil` never matches an active zone
    filter. That's defensible in isolation. But `ReportSheet.swift` — the only shipped write path
    for `enforcement_active`/`sweeper_passed` — explicitly passes `zoneId: nil` on every insert.
    There is no other write path yet that fills in `zone_id` (Phase 2's `insertCrowdPin` additions,
    per the spec, only add `positionFraction`/`leavingMinutes` parameters — zone assignment on
    insert isn't in scope anywhere in the spec I could find). Net effect: once the flag flips on,
    the crew feed's zone-filtered pin half will show **zero** real-world enforcement/sweeper
    reports, ever, until some future phase adds zone-on-insert logic. This is a materially
    different (and worse) statement than the PR body's own documented limitation ("a zone far from
    where the map is centered can show fewer/no pins") — it's not about map position, it's that the
    join key is unpopulated everywhere.
  - Expected: not explicitly required by any single AC, but it undercuts AC-P1.1/AC-P1.2's spirit
    ("appears... in the crew feed") for the one pin type category (enforcement/sweeper) that
    actually has live production data today.
  - Owner: `@backend-data` / `@ios-engineer` — needs a zone-on-insert story (server-side lookup by
    lat/lng against `public.zones`' bounding boxes would be the obvious mechanism, mirroring
    OQ-1's box-not-polygon decision) before the crew feed can show anything beyond
    open_spot/leaving_soon pins from a not-yet-built Phase 2 write path. Track this explicitly —
    it isn't called out anywhere in the PR body or the reconciliation spec today.

### 🟢 Minor / nit

- **#4: PR body test-count claims are slightly off (undercounts, not overcounts).** PR body says
  "37 tests" for `CrewFeedSectionTests.swift`; actual is 38. Says "+4 tests in
  `MarkerImageSafetyNetTests`" for `Tier3PinFeedbackTests.swift`; actual diff adds 8 (4 marker
  tests + 4 TTL tests for the OQ-2 45m/120m change, likely in a different test class within the
  same file). Total new tests across all 6 touched/added test files by my count: 97 (23 + 38 + 18
  + 7 + 8 + 3), not the "41 + 41 = 82" implied by the two session summaries, and somewhat more than
  the 92 the dispatching task expected. Direction is fine (more tests, not fewer), but the
  per-file accounting in both PR-body sessions doesn't reconcile — harmless today, but exactly the
  kind of stale-count drift `CommunityPinServiceTests.swift`'s own header comment already flags as
  having happened once before in this file.
- **#5: Crew-feed empty-state copy is "spirit," not verbatim, despite echoing prototype language.**
  `prototype.html:881`'s block-detail chat empty state is "No chatter yet" / "Be the first — crews
  form block by block." The shipped copy is "No reports yet" / "Crews form block by block — be the
  first to post here." — a reasonable, arguably more accurate paraphrase (the feed isn't only chat),
  but spec §6's verbatim-copy list doesn't cover this string, so this isn't a violation, just noting
  it for the record since the PR body's wording ("matches... spirit," correctly hedged) implies it
  already knows this.

### 💡 Out of scope (logged, not fixed)

- **AC-P1.2's map-region-fetch clause** (zone chips don't move/refetch by map bounding box) — PR
  body classifies this as a partial completion, correctly scoped out of this session's stated
  dispatch instructions. Acceptable deferral; track under Phase 1 follow-up or Phase 2.
- **`PinDetailSheet.swift` generic styling for `open_spot`/`leaving_soon`** — confirmed zero diff
  to that file (`git diff --stat` empty). Falls through existing `default:` branches, cosmetic gap
  only, correctly out of this session's listed file scope. Acceptable deferral; flag for whoever
  picks up Phase 2/3 detail-sheet polish, as the PR body already does.
- **`positionFraction` unused for map placement** — correctly identified as "no code needed, not a
  deferral" (there's no segment-midpoint rendering path on iOS for it to slot into); verified true
  by reading `CommunityPinAnnotation.coordinate`, which renders from `lat`/`lng` directly for every
  type. Not a finding.
- **`claim_pin` RPC wiring** — explicit, disabled stub button + "Coming soon" caption, correctly
  scoped to Phase 3 per the session's own dispatch instructions. Verified: the button's action
  closure is a documented no-op, not a silent dead click.

## Smoke tests run

This is a **code-level review only** — no Xcode/simulator access on this VPS (consistent with the
PR's own posture; both S3 and S4 are `[COMPILE-UNVERIFIED]`). Specifically:

- Read every changed/added production file in the diff (`CommunityPin.swift`,
  `CommunityPinService.swift`, `RealtimeMergeGate.swift`, `SupabaseClients.swift`,
  `ZoneMessageService.swift` (new), `BrowseNavigationSheet.swift`, `CrewFeedSection.swift` (new),
  `PinMarkerAnnotation.swift`, `ContentView.swift`, `Constants.swift`) against the reconciliation
  spec §2/§3/§6 and against `ft20-bottom-sheet-navigation-spec.md` §0f.
- Confirmed `pins.zone_id`, `position_fraction`, `leaving_minutes`, `claimed_by` all exist in
  `supabase/02-pins-schema.sql`/`03-community-2.0-schema.sql`, and that the widened `select=` list
  in Channel 2's fetch request names them correctly (`grep` cross-check, no typos).
  `pins_with_author`'s view definition (§2.11's note) also carries the three new columns through —
  verified against `03-community-2.0-schema.sql` lines ~658-660.
- Traced `AppConstants.communityEnabled`'s only 6 call sites (all `grep`-confirmed in
  `ContentView.swift`) against every place the two new `PinType` cases actually become reachable —
  this is how Finding #1 was found (not from the PR body, which doesn't mention this gap).
  `grep communityEnabled` across `Services/CommunityPinService.swift` and
  `Services/RealtimeMergeGate.swift` returns zero hits — confirmed absence, not just spot-check.
- Traced `BrowseNavigationSheet.swift`'s `.large`-detent VStack children before and after the diff
  to reason about SwiftUI's stack-layout space distribution — this is how Finding #2 was found.
  **Not confirmed visually** — this is a code-reading inference from documented SwiftUI stack
  layout behavior plus this exact file's own precedent bug class (FT-20 §0d C1), not a screenshot.
  Flagging explicitly per this role's "don't silently pass on a 70%-sure claim" standard.
- Verified `UIColor.systemBlue`'s dark-mode value against Apple's documented dynamic system colors
  (`#0A84FF` in dark appearance, `#007AFF` in light) and confirmed the app forces
  `.preferredColorScheme(.dark)` (`WeParkApp.swift:183`) — the spec §6 color claim for
  `open_spot`/`leaving_soon` checks out without a hardcoded RGB literal.
- Read all 97 new/added test bodies at the function-signature level and spot-checked ~15 full test
  bodies (`CrewFeedSectionTests.swift`'s ordering/zone-filter tests, `RealtimeMergeGateZoneTests`,
  `ZoneMessageServiceTests`'s realtime insert tests) — these assert real behavior (exact ordering,
  exact exclusion/inclusion, decode round-trips via JSON fixtures rather than memberwise inits),
  not shape-only construction. No test found that would pass with the feature broken.
- Grepped all new/changed Community 2.0 files for "avoid," "ticket," "fine," "evasion," "dodge" —
  zero hits. Copy audit passes.
- Confirmed `PinDetailSheet.swift` has zero diff (matches PR body's claim, `git diff --stat` empty
  for that path in this branch range).
- Read `docs/ft20-bottom-sheet-navigation-spec.md` in full to evaluate the detent-reuse decision
  (Focus Area #1) against Kevin's actual §0e/§0f rulings, not just the reconciliation spec's
  (partially inaccurate) characterization of FT-20's detent count.

**Not run, and explicitly required before merge regardless of this report's verdict:**
Kevin's Mac `xcodebuild build`/`test` pass, and the live-simulator smoke (AC-P1.5) — which must
specifically include (a) inserting a test `open_spot` pin into prod-shaped data with the shipped
`communityEnabled = false` and confirming it does **not** render on-map (Finding #1), and (b)
comparing `.large`'s recents/suggestions list height with the flag off against a build from
`origin/main` at the same detent (Finding #2), in addition to the toolbar/ASP-banner/Park-Until-pill
checklist already planned in the PR body.

## What's working

- **The detent-reuse decision (Focus Area #1) is the right call, not a compromise.** The
  reconciliation spec's own framing — "FT-20 ships exactly two custom detents (peek + medium)... the
  crew feed needs a third, taller state" — doesn't match the actual shipped FT-20 spec or code:
  `BrowseSheetDetentKind` has always had three cases (`peek, medium, large`), and `.large` has been
  a live, reachable member of `.browseNav`'s `.presentationDetents` array since FT-20 shipped,
  already used for `BrowseSearchAreaView`'s recents/suggestions/place-state content at full height.
  `.large` already *is* the prototype's "full" state (peek≈collapsed, medium≈half, large≈full) —
  inventing a fourth detent height to satisfy a request for a "third" one would have been the actual
  mistake here. S4 correctly identified this and reused `.large` with a clear, well-reasoned doc
  comment rather than either blindly following the spec's inaccurate premise or silently
  reinterpreting scope without explanation. This does not violate Kevin's §0f "no extra chrome at
  rest" ruling — the crew feed only appears at an already-pulled-up state, same category as today's
  search content. (The layout-competition consequence of *how* it was wired in — Finding #2 — is a
  separate, real bug; the *decision* to reuse `.large` is sound.)
- Peek and medium detents are genuinely, verifiably untouched — confirmed by diff, not just by the
  PR body's claim.
- The model layer (S3) is careful about the encode/decode write-grant boundary: `claimedBy` is
  correctly decode-only (never encoded), matching the schema's own `INSERT` grant list
  (`position_fraction`/`leaving_minutes` granted, `claimed_by` deliberately not), and this is
  actually tested (`testEncode_claimedBy_neverWritesKey_evenWhenPresent`).
  `ephemeralTTLSeconds(for:leavingMinutes:)`'s default-nil parameter is genuinely backward
  compatible — confirmed by reading every existing call site, none of which pass the new argument.
  The OQ-2 45m/120m TTL reversal is the correct interpretation of Kevin's resolved decision and is
  tested with concrete boundary values.
- The `RealtimeMergeGate.isInZone` zone dimension is a clean, minimal, well-tested addition that
  matches the spec's own explicit architectural recommendation ("keep one channel, add zone_id as
  one more dimension" rather than N channels) — no new sockets, no new channels, pure client-side
  gating logic with direct unit tests.
- `UIColor.systemBlue`'s dark-mode value genuinely resolves to spec's `#0A84FF` without a
  hardcoded literal — a nice, verifiable-without-a-device design choice.
- Confirm/dispute/claim wiring in `CrewFeedSection.swift` correctly reuses the existing
  `upsertVote`/`callExtendPinExpiry` write path rather than inventing a parallel one, correctly
  gates on `showsReactionsRow && !isOwnPin`, and correctly special-cases `leaving_soon` to route to
  a claim affordance instead — with the claim button an honest, disabled, explicitly-commented stub
  rather than a silently-broken or fake-succeeding control.
- Copy audit is clean (no banned words), and every deferral I could find (position_fraction
  placement, PinDetailSheet styling, claim_pin wiring, map-region-fetch clause) is honestly
  documented in the code and the PR body rather than silently dropped.
