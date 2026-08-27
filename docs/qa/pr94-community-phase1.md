# Community 2.0 Phase 1 (S3+S4) QA Pass 1 — 2026-08-27

**Reviewed:** branch `ios/community-phase1` @ `4034466b` (S4, on top of S3 `a232b75a`), against
`docs/community-2.0-reconciliation-spec.md` §3 Phase 1 + §6, `docs/ft20-bottom-sheet-navigation-spec.md`
§0f, and `design/prototype.html`. Diff base: `origin/main` @ `eb19b947`.
**Verdict (superseded by Pass 2 below):** 🔴 **FIX-THEN-MERGE** — two blocking findings, both
fixable without a large rewrite.

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

- **#4: PR body test-count claims are slightly off (undercounts, not overcounts).** *(Correction
  in Pass 2: this finding was itself an artifact of my own diff-line-counting method, not a real
  discrepancy — see Pass 2's "Test count" section. `git grep`, the authoritative method, shows the
  PR body's "41+41" framing understates per-file detail but the total (92 added, 872→964) is
  exactly right.)* PR body says "37 tests" for `CrewFeedSectionTests.swift`; actual is 38. Says
  "+4 tests in `MarkerImageSafetyNetTests`" for `Tier3PinFeedbackTests.swift`; actual diff adds 8.
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

## Smoke tests run (Pass 1)

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
- Traced `AppConstants.communityEnabled`'s only 6 call sites (all `grep`-confirmed in
  `ContentView.swift`) against every place the two new `PinType` cases actually become reachable —
  this is how Finding #1 was found (not from the PR body, which doesn't mention this gap).
- Traced `BrowseNavigationSheet.swift`'s `.large`-detent VStack children before and after the diff
  to reason about SwiftUI's stack-layout space distribution — this is how Finding #2 was found.
  **Not confirmed visually** — a code-reading inference from SwiftUI stack layout semantics plus
  this exact file's own precedent bug class (FT-20 §0d C1), not a screenshot.
- Verified `UIColor.systemBlue`'s dark-mode value against Apple's documented dynamic system colors
  (`#0A84FF` in dark appearance) and confirmed the app forces `.preferredColorScheme(.dark)`.
- Read all new test bodies at the function-signature level and spot-checked ~15 full test bodies —
  these assert real behavior, not shape-only construction.
- Grepped all new/changed Community 2.0 files for "avoid," "ticket," "fine," "evasion," "dodge" —
  zero hits.
- Confirmed `PinDetailSheet.swift` has zero diff.

## What's working (Pass 1)

- **The detent-reuse decision is the right call, not a compromise.** The reconciliation spec's own
  framing — "FT-20 ships exactly two custom detents (peek + medium)... the crew feed needs a third,
  taller state" — doesn't match the actual shipped FT-20 spec or code: `BrowseSheetDetentKind` has
  always had three cases (`peek, medium, large`), and `.large` has been a live, reachable member of
  `.browseNav`'s `.presentationDetents` array since FT-20 shipped. `.large` already *is* the
  prototype's "full" state (peek≈collapsed, medium≈half, large≈full) — inventing a fourth detent
  height would have been the actual mistake here. This does not violate Kevin's §0f "no extra
  chrome at rest" ruling.
- Peek and medium detents are genuinely, verifiably untouched — confirmed by diff.
- The model layer (S3) is careful about the encode/decode write-grant boundary, the OQ-2 45m/120m
  TTL reversal is correctly implemented and tested, and `RealtimeMergeGate.isInZone` is a clean,
  minimal, well-tested addition matching the spec's own architectural recommendation.
- `UIColor.systemBlue`'s dark-mode value genuinely resolves to spec's `#0A84FF` without a
  hardcoded literal.
- Confirm/dispute/claim wiring in `CrewFeedSection.swift` correctly reuses the existing write path,
  correctly gates eligibility, and the claim button is an honest, disabled, explicitly-commented
  stub rather than a silently-broken control.
- Copy audit is clean, and every deferral is honestly documented rather than silently dropped.

---

# QA Pass 2 — 2026-08-27

**Reviewed:** branch `ios/community-phase1` @ `c2ac24b5` (fix commit on top of `4034466b`), against
Pass 1's two blocking + one significant finding, re-verified cold against
`docs/community-2.0-reconciliation-spec.md`, `supabase/03-community-2.0-schema.sql`, and
`docs/ft20-bottom-sheet-navigation-spec.md` §0d/§0f.

**Verdict:** 🟡 **MERGE-AFTER-MAC-GATE.** All three Pass-1 findings are fixed correctly at the code
level, verified cold by re-tracing every seam and re-deriving the layout math independently rather
than trusting the fix commit's own description. No new blocking issues introduced by the fixes. One
residual, non-blocking caveat on the layout formula's precision on small screens (documented below,
explicitly not a redo). Kevin's Mac gate (build + full test run + live-sim smoke) is the only thing
standing between this branch and merge.

## Per-finding verification

- **Finding #1 (flag gating) — CONFIRMED FIXED, cold-verified at all three seams plus a full
  repo-wide sweep for a fourth.** `AppConstants.communityPhase1PinTypes(enabled:)`
  (`Services/Constants.swift`) is a pure function, `[]` when `enabled == false`, and is genuinely
  the single source every seam routes through:
  - `CommunityPinService.channel2PinTypeQueryValue(communityEnabled:)` builds the actual
    `pin_type=in.(...)` **query string** dynamically. Verified the flag-off value equals
    `"in.(enforcement_active,sweeper_passed)"` — byte-identical to `origin/main`'s pre-PR literal
    (confirmed by diffing `origin/main`'s `buildCrowdEphemeralRequest` against this branch's) — and
    the flag-on value equals `"in.(enforcement_active,sweeper_passed,open_spot,leaving_soon)"`,
    identical to what `4034466b` shipped unconditionally. `isChannel2Member` now builds its
    eligible-types set through the same helper. This is a genuine "never even requested" fix, not
    just a post-fetch filter.
  - `RealtimeMergeGate.mergeablePinTypes` is now a computed property reading the real flag, backed
    by a pure `computeMergeablePinTypes(communityEnabled:)` + an unparameterized `baseMergeablePinTypes`
    that (verified) no longer contains `.openSpot`/`.leavingSoon` at all — they only enter via the
    union with `communityPhase1PinTypes(enabled:)`.
  - `ContentView.mapMarkerTypes(communityEnabled:)` — extracted to a `nonisolated static func`,
    same union pattern, called from `handleVisiblePinsChange` with the real flag.
  - **Fourth-seam hunt:** extracted the full `c2ac24b5` production tree (`git archive`) and grepped
    `openSpot|leavingSoon|open_spot|leaving_soon` across every `ios/WePark/WePark/*.swift` file
    (not test files). Every remaining hit is either (a) doc comments, (b) the `PinType` enum
    case/model-layer `Codable` plumbing (`CommunityPin.swift` — decode-layer, correctly out of
    scope per this pass's own instruction), or (c) pure display-formatting switches
    (`PinMarkerAnnotation.swift`'s `displayLabel`/`subtitle`/`markerImage`/`ringMarkerImage`,
    `CrewFeedSection.swift`'s `icon(for:)`) that only execute on a `CommunityPin` instance already
    past the three gated seams above — these can never independently leak a pin into `visiblePins`
    or a map annotation. **No fourth seam found.**
  - Also re-verified the `select=` query param still unconditionally requests
    `position_fraction,leaving_minutes,claimed_by` regardless of the flag — correctly left
    unguarded (requesting three extra, always-nil-for-existing-types columns from PostgREST has no
    security/behavior implication; `CommunityPin`'s decode is nil-safe either way). This is not a
    seam that needs gating, and the fix commit correctly didn't touch it.
  - **Tests genuinely flip the flag both ways and would fail on regression.** Spot-verified 4 of the
    18: `testChannel2PinTypeQueryValue_flagFalse/True_...` assert the exact query string in both
    states; `testComputeMergeablePinTypes_flagFalse/True_...` assert `RealtimeMergeGate` set
    membership in both states; `testMapMarkerTypes_flagFalse/True_...`
    (`FT20StreamCTests.swift`) assert `ContentView.mapMarkerTypes` in both states, and also assert
    the pre-existing Tier 1/3 types are unaffected by the flag (guards against an over-broad fix
    that accidentally gates everything). One S3 test that had asserted the *bug* as correct
    behavior (`testMergeablePinTypes_containsExpectedTypes_excludesIneligibleTypes`, which
    asserted `.openSpot`/`.leavingSoon` WERE unconditionally mergeable) is corrected in place,
    renamed, and now asserts the opposite — a real regression-test fix, not just an addition.

- **Finding #2 (layout) — CONFIRMED FIXED for the flag-off case; the flag-on formula is a
  reasonable, honestly-flagged approximation, not a proven-correct measurement.**
  - The `.large` mount site's `if` is now `if detentKind == .large, AppConstants.communityEnabled`
    — the flag check moved from inside `ContentView`'s closure content to the mount condition
    itself. Diffed `BrowseNavigationSheet.body`'s structure on `c2ac24b5` against `origin/main`'s
    pre-PR version directly: with `communityEnabled` a compile-time-constant `false` `let`, this
    branch's entire body (including the `.frame(maxHeight:)` call) is unreachable, and the VStack
    has the **exact same two structural children** (`searchArea`, conditionally `actionColumn`)
    `origin/main` has — not a third node that happens to render nothing. This is a genuine
    "same view tree," not just "same rendered pixels," fix — confirmed by reading the actual
    `body` source on both commits side by side, not by trusting the fix's own doc comment.
  - `.frame(maxHeight: .infinity)` (the actual bug) is replaced with `.frame(maxHeight:
    crewFeedMaxHeight)`, an explicit ceiling (`activeScreenHeight * 0.5`) — no longer a second
    unbounded-flexible sibling. Since `searchArea` remains the VStack's only truly *unbounded*
    flexible child, and the crew feed now has a hard upper bound, SwiftUI's stack-layout algorithm
    will size the crew feed to at most its cap and give `searchArea` everything else — this
    correctly eliminates the specific failure mode from Pass 1 (an even, uncontrolled 50/50-ish
    split that could squeeze search's `List` arbitrarily thin as the crew feed's content grows).
  - **Small-screen sanity check (as requested) — the "at least half of `.large`'s available
    height" framing in the fix's own doc comment is imprecise, not wrong-in-effect.**
    `crewFeedMaxHeight` is computed as 50% of **total screen height**, not 50% of `.large`'s
    *usable content* height (screen height minus the sheet's own top inset, minus the search
    field, minus the gutter, minus `actionColumn`). On an SE-class device (~667pt logical height),
    that fixed overhead (search field ~76pt + gutter + `actionColumn` ~90–110pt, per this file's
    own round-6 on-device numbers from a larger device, likely similar order of magnitude here)
    could consume a large-enough fraction of the sheet's `.large` budget that the true remaining
    room for `searchArea` + crew feed combined is meaningfully less than the full screen height —
    meaning a crew feed that actually uses its full 50%-of-screen cap could take noticeably *more*
    than 50% of what's *actually left over* for the two to share, on a small device specifically.
    This does **not** reintroduce Pass 1's bug (search can never be squeezed to near-zero, because
    the cap is still a hard, finite ceiling, and `searchArea`'s own `.frame(minHeight:
    minimumPeekHeight)` floor is untouched) — but on an SE-class phone with a fully-populated crew
    feed, the search recents/suggestions list could plausibly render shorter than the fix's own
    "at least half" framing implies. **This is acceptable-for-smoke, not a redo**: it's a bounded,
    non-catastrophic imprecision in a formula the engineer already flagged
    `[COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK]` in the same style as this file's pre-existing
    `maxAllowedMediumHeight`. It needs an explicit SE-class check in Kevin's live smoke (see below),
    not a code change before merge.
  - **The visual half of this verification belongs to Kevin's live smoke, explicitly** — nothing
    above is a screenshot-confirmed claim; it's a code-reading derivation from SwiftUI stack-layout
    semantics, same epistemic status as Pass 1's original finding.

- **Finding #3 (zone fallback) — CONFIRMED FIXED, values verified byte-for-byte, fallback
  direction and boundary behavior verified by both reading and by the new tests.**
  - `CommunityZoneBounds`'s three hardcoded boxes were diffed directly against
    `supabase/03-community-2.0-schema.sql`'s applied seed `insert` statement (lines ~134-137):
    `nolita (40.7217, 40.7256, -73.9967, -73.9930)`, `soho (40.7220, 40.7237, -74.0050, -73.9970)`,
    `les (40.7145, 40.7230, -73.9920, -73.9800)` — **exact match on all 12 numbers**, including the
    corrected `soho` `lat_max` of `40.7237` (not the stale `40.7280` Pass 1 of the *schema* PR
    caught — confirmed the schema file's own comment documents this as "QA pass 1 fix (Finding
    #5, docs/qa/pr93-community-phase0-schema.md)", and this branch's fallback table correctly used
    the corrected value, not the stale one).
  - `resolvedZoneId(for:)` is `pin.zoneId ?? CommunityZoneBounds.zoneId(forLat:lng:)` — nil-coalescing
    means a non-nil server value is always used as-is and never overridden by the box lookup.
    Verified by a dedicated test that deliberately puts a pin at coordinates inside a *different*
    zone's box than its explicit `zoneId`: `testResolvedZoneId_pinHasExplicitZoneId_usedDirectly_
    boundingBoxIgnored` (`zoneId: "les"`, coordinate inside nolita's box) asserts the resolved zone
    is still `"les"` — this is exactly the "never overrides a server value" property, not just
    inferred from reading the `??` operator.
  - **Boundary behavior — computed the three boxes' lat/lng ranges by hand; none overlap.**
    nolita's lng range ends at `-73.9930`... wait, ends at `-73.9930` as its *max* (least negative);
    soho's lng range is entirely west of nolita's (max `-73.9970` vs. nolita's min `-73.9967`, a
    real ~30m gap, no shared edge); les's lng range (min `-73.9920`) sits fully east of nolita's max
    (`-73.9930`, ~85m gap). No two boxes share a border in the applied migration, so there is no
    coordinate that could satisfy two boxes simultaneously — "deterministic, no double-count" holds
    by construction, not merely by `.first` winning an ambiguous case. Verified the code's own
    boundary test (`testZoneId_exactBoundaryCoordinate_included`, nolita's exact `(latMin, lngMin)`
    corner) uses closed intervals (`>=`/`<=`) consistently with `RealtimeMergeGate.isWithinRegion`'s
    existing convention.
  - `docs/community-2.0-roadmap.md`'s S6 row now explicitly carries the "stamp `zone_id`
    server-side on insert" follow-up, with a direct pointer back to this finding and an honest
    characterization of the client-side fallback as "a display-only patch, not a cure for the
    underlying null column" — confirmed present in the diff, not just claimed in the commit message.

## New issues introduced by the fixes? None found.

- **Query-construction refactor (the riskiest single change) does not alter the existing-type
  query.** Directly diffed `origin/main`'s literal `pin_type=in.(enforcement_active,sweeper_passed)`
  against `channel2PinTypeQueryValue(communityEnabled: false)`'s output — identical string, same
  ordering. The flag-on value is also unchanged from what `4034466b` originally shipped
  unconditionally (`...,open_spot,leaving_soon)`, same order). No silent reordering, no typo in a
  `PinType.rawValue`, no dropped existing type.
  - There is a nomenclature note worth flagging (not a bug): `channel2PinTypeQueryValue`'s parameter
    is externally-labeled `communityEnabled:`, matching `AppConstants.communityEnabled`'s name, but
    it's actually threading through `AppConstants.communityPhase1PinTypes(enabled:)` — fine as
    implemented, just a two-hop naming chain worth being aware of if a future engineer greps for
    "communityEnabled" expecting to find every gate in one pass (they'd still find this one, since
    the parameter itself is named `communityEnabled`, so this is a non-issue in practice — noting
    only because Pass 1's whole finding was exactly this kind of "grep didn't find it" gap).
  - `mergeablePinTypes` and `mapMarkerTypes` both now read `AppConstants.communityEnabled` at their
    call sites rather than being handed it as an argument at the top of a call chain — reconfirmed
    this doesn't introduce a race or staleness risk: `communityEnabled` is a compile-time `let`
    constant (not a `@Published`/runtime-mutable flag), so "when" it's read is immaterial — there's
    only ever one value for the lifetime of the process.
- **No regression to the model-layer, TTL, or copy work** — none of those files were touched by the
  fix commit (`Community2Phase1ModelTests.swift`'s diff is additive-only, a new test class; no
  production model file changed).

## Test count (exact, `git grep`, authoritative — supersedes Pass 1's diff-based estimate)

Pass 1's "97 by my count" was itself wrong — an artifact of counting `+`-prefixed lines in a unified
diff, which double-counts context-adjacent additions inconsistently. `git grep -E '^\s*func test'`
against each commit directly is authoritative:

- `origin/main`: **872** test functions.
- `4034466b` (S3+S4, Pass 1's review target): **964** — exactly 872 + 92, matching the orchestrator's
  original expectation precisely (Pass 1's "97" estimate was noise from the diff-counting method,
  not a real discrepancy in the PR — retracting that part of Pass 1 Finding #4 above).
- `c2ac24b5` (this pass's review target, current head): **982** — exactly 964 + 18, matching the fix
  commit's own claimed count exactly. Per-file deltas also verified individually and match the
  commit message's breakdown exactly: `Community2Phase1ModelTests.swift` +3, `CommunityPinServiceTests.swift`
  +4, `CrewFeedSectionTests.swift` +9, `FT20StreamCTests.swift` +2 (23+38+18 in the other three
  untouched Community 2.0 test files unchanged).

**Exact expected test count for Kevin's `xcodebuild test` run on `c2ac24b5`: 982.**

## What Kevin's Mac live-sim smoke must specifically exercise

In addition to the standard AC-P1.5 checklist already in the PR body (toolbar/ASP-banner/Park-Until-
pill still render, no #31-class regression):

1. **Finding #1's scenario**: with the shipped `communityEnabled = false`, insert a test
   `open_spot`/`leaving_soon` row into the pins table (e.g. re-run `03-community-2.0-test.sh`
   without its cleanup step, or manually via the dashboard) and confirm it does **not** appear as a
   map marker on a build from this branch. This is now expected to pass; Pass 1 found it would have
   failed on `4034466b`.
2. **Finding #2's scenario, both flag states**:
   - Flag off: confirm `.large`'s search recents/suggestions list renders identically to a build
     from `origin/main` at the same detent (byte-identical view tree, so this should be a trivial
     pass, but is the direct visual confirmation the code-level fix can't provide on this VPS).
   - Flag on, crew feed populated with several rows, **specifically on an SE-class simulator** (not
     just iPhone 17): confirm neither the search list nor the crew feed is uncomfortably cramped.
     This is the one open, non-blocking question from this pass — expected to be fine, not
     confirmed.
3. **Finding #3's scenario**: with the flag on, confirm a zone chip (e.g. Nolita) shows existing
   `enforcement_active`/`sweeper_passed` pins whose coordinates fall inside that zone's box, even
   though those pins' `zone_id` column is `nil` in the database — this is the fallback actually
   working end-to-end against live data, not just the unit-tested pure function.

## Verdict

🟡 **MERGE-AFTER-MAC-GATE.** All Pass 1 findings are correctly and completely fixed at the code
level; no new issues were introduced by the fixes; the one residual caveat (small-screen layout
precision) is explicitly non-blocking and folded into the required live-sim smoke rather than
gating the merge itself. Kevin's Mac gate — `xcodebuild build`, `xcodebuild test` (expect exactly
**982** passing), and the live-sim smoke covering the three scenarios above plus the standard
AC-P1.5 checklist — is the only remaining step before merge.
