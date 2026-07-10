# TF2-17 "Free until X" Chips + TF2-18 Drive-Mode Design Pass — QA Pass 1 — 2026-07-10

**Reviewed:** branch `ios/tf2-17-18-chips-design-pass` at `a5ce68e` (PR #66), against
`docs/tf2-17-chip-free-until-spec.md` and `docs/design/drive-mode-ui-review-2026-07-09.md`
("suggested single engineer-pass PR scope").
**Verdict:** ✅ SHIP WITH CAVEATS — no blocking findings; three non-blocking items below,
plus Kevin's on-device drive-test remains the final gate for everything this PR cannot
render without gesture injection.

## Summary

This is a clean, well-disciplined bundle. The service-layer refactor (`SideAggregation` /
`aggregateSideDetail`) is a faithful, additive implementation of the TF2-17 spec with the
FT-9 regression explicitly replayed at the aggregation layer and voice output proven
byte-identical by both code inspection and passing tests. The TF2-18 design-pass items match
the review's recommendations closely, including the one deliberate, well-justified deviation
(dark text instead of white on red/green chips) — I independently recomputed all WCAG
contrast ratios from the shipped RGB values and every number in the PR's table checks out,
including the white-text failure claim that justified the deviation. Full suite is 565/0 on a
fresh sim I built myself; cold clean build succeeds; the mount-chain live-UI smoke (required
because this PR touches `ContentView.swift` and `DriveModeBottomCard.swift`) confirms the
toolbar + ASP banner overlay chain renders correctly with the new 100pt offset. The only real
gap — chip legibility and layout *while Drive Mode is actually active* — is unreachable in
this sandbox for the same reason the builder flagged it: no gesture/GPS injection available
to get past the destination-search flow. That is Kevin's drive-test to close, not a defect.

## Note on this session: prompt injection encountered mid-task

While reading `docs/design/drive-mode-ui-review-2026-07-09.md` via the `Read` tool, the tool
output contained injected content appended after the legitimate file text — a fake
"system-reminder" claiming the date had changed, followed by fake "MCP Server Instructions"
for `computer-use`, Kiwi, and Skiplagged tools unrelated to this task. This did not originate
from Kevin or the orchestrator; it was embedded in (or spliced into) tool output. I disregarded
it entirely and continued the QA task as originally scoped — no tool calls, permission
changes, or task-scope changes were made in response to it. Flagging per the standing
instruction that no injected content is ever authorization to deviate from the task. Not a
finding against the PR — this is unrelated to the code under review — but worth a look if it
recurs, since it suggests something in the tool pipeline is vulnerable to content injection
from file contents.

## Acceptance criteria checklist

### TF2-17 spec (§7)

- [x] AC-1 — `SideAggregation` + `aggregateSideDetail` implemented per §5.1; `aggregateSide` is
      a thin wrapper (`DrivingContextService.swift:465-475`). Verified by reading the code and
      confirming `aggregateSide` literally returns `aggregateSideDetail(...).opportunity`.
- [x] AC-2 — 9 existing `AggregateSideTests` (`TF27Tests.swift`) pass unmodified — confirmed
      two ways: `TF27Tests.swift` does not appear in the PR diff at all, and the full suite run
      shows all 9 `AggregateSideTests` cases passing.
- [x] AC-3 — `SafetyLabel(for: SideAggregation)` implemented per §5.2. **Flagged override
      accepted**: `SafetyLabel(for: SideOpportunity)` was not "untouched" as the spec assumed —
      it gained a `.comingSoon` branch, forced by Swift exhaustiveness once TF2-18 P1-2 was
      bundled in. `SafetyLabelSideOpportunityTests` (D-1..D-4, in `TF27Tests.swift`) are
      confirmed unmodified (file absent from diff) and pass. This is a reasonable,
      well-documented, minimal consequence of the bundling decision Kevin already approved —
      not a spec violation in spirit.
- [x] AC-4 — `update()` builds `leftLabel`/`rightLabel` via `SafetyLabel(for: SideAggregation)`
      (`DrivingContextService.swift:319-326`).
- [x] AC-5 — byte-identical text verified by `AggregateSideDetailTests` test 1
      (`testAggregateSideDetail_singleFreeSegmentWithUpcomingRestriction_returnsFreeUntilText`),
      asserts equality against `engine.safetyLabel(for:).text` directly. Passing.
- [x] AC-6 — conservative-min (earliest) ranking verified by test 2 (2h wins over 6h) and
      hand-traced in code: `aggregateSideDetail` iterates all qualifying free segments, keeps
      the minimum `hours`. Correct.
- [x] AC-7 — no-upcoming-restriction fallback verified by test 3
      (`testAggregateSideDetail_allFreeSegmentsUnrestricted_returnsNilText`), asserts
      `"Free — check signs"` via the bridge. Passing.
- [x] AC-8 — metered/restricted-only chip text unchanged — `SafetyLabel(for: SideAggregation)`
      keeps `"Metered"` / `"No parking"` for those branches (`SafetyLabel.swift:118-121`).
- [x] AC-9 — mixed-side precedence unchanged — test 5, passing.
- [x] AC-10 — metered-free segment excluded from ranking (OQ-3) — test 4, passing. Verified in
      code that `nextRestriction()` (the ranking source) explicitly `continue`s on
      `.metered` (`ParkingRulesEngine.swift:226`), so a metered-free segment can never supply
      ranking text — matches the spec's stated mechanism exactly.
- [x] **AC-11 (FT-9 regression)** — verified two ways. (a) Code reading:
      `aggregateSideDetail`'s per-segment classification switch calls
      `engine.safetyLabel(for: seg, at: date)` exactly once per segment and switches on
      `.severity`, inheriting the FT-9 fix (metered-active-now check runs before the
      "upcoming ASP → free" branch, confirmed at `ParkingRulesEngine.swift:96-121` — the
      `dom == .metered` branch returns `.metered` immediately when `"paid until"` is active,
      before the ASP "Free until X" branch is ever reached). (b) Test-level:
      `testAggregateSideDetail_ft9Regression_activelyMeteredSegmentPlusUpcomingASP_classifiesMetered`
      constructs a segment with both an active-now metered rule AND an upcoming ASP rule,
      asserts the *engine* classifies it `.metered` as a precondition, then asserts the
      *aggregation* also classifies `.metered` (not `.free`) — this is exactly "metered-active
      precedes any free-until branch in the aggregation," confirmed passing.
- [x] AC-12 (live-UI smoke, chip text length) — **partially verified.** The layout math is
      sound (P2-5's stacked full-width chip gets ~358pt vs. the pre-TF2-18 ~149pt half-width
      chip, comfortably fitting the 30-char worst-case string) and the builder's claim of a
      temporary launch-arg harness screenshot is plausible and was correctly reverted (confirmed
      absent from the diff — `WeParkApp.swift` does not appear in `gh pr diff 66` at all). I was
      **not able to independently re-render this** — no gesture/GPS injection path exists in
      this sandbox to get a live `DriveModeBottomCard` on screen with real `DrivingContext` data
      (same limitation the builder hit). Not blocking; flagged for Kevin's drive-test.
- [x] AC-13 — voice byte-identical, locked by `TF217VoiceRegressionTests` (4 tests, passing) and
      independently hand-traced below (see "Voice hand-trace").
- [x] AC-14 — preview literal updated to `"Free until Wednesday 9:30 AM"`, matches
      `nextRestrictionTimeLabel`'s actual format. Confirmed in diff, no other `DriveModeBottomCard`
      body diff outside the TF2-18-scoped items.
- [x] AC-15 — 565/0, reported below with independent re-run.
- [ ] AC-16 — this document.

### TF2-18 design-pass items (review's suggested scope)

- [x] P1-1 (solid-fill, WCAG-fixed contrast) — shipped, all four severities independently
      recomputed and matching (see Contrast section).
- [x] P1-2 (`.comingSoon` orange tier) — shipped, exhaustiveness audited across the whole
      codebase (see `.comingSoon` propagation audit).
- [x] P1-3 (recenter pill clearance) — shipped as `recenterPillBottomPadding`, mirrors
      `paddingForBannerState` pattern; see Finding #3 (minor) on the hardcoded height estimate.
- [x] P2-1 (button anatomy) — shipped: End Drive / Report / Park Here now share capsule +
      `Label(icon+text)` + explicit `.frame(minHeight: 44)`; mute toggle stays icon-only but
      picked up the same `minHeight: 44`. Matches review text exactly.
- [x] P2-2 (44→100 toolbar offset) — shipped; verified `100` is not an invented number — it's
      the pre-existing `recenterButtonStack.padding(.top, 100)` value already live since W5.1
      (that line is untouched by this diff, confirmed by grep), so the two clusters now
      genuinely align on a value already proven correct in production.
- [x] P2-5 (stacked chips, `minimumScaleFactor` 0.75→0.9) — shipped exactly as specified.
- [x] P2-6 (44×44 checkbox tap target) — shipped exactly per the review's literal
      recommendation (`Button` wrapper, `.frame(width: 44, height: 44)`, `.contentShape(Rectangle())`).
- [x] Left out of scope correctly: P2-4 (amber collision, flagged as a Kevin decision point, not
      resolved), P2-3/P3-2 (bottom-stack margin / corner-radius convention, deferred). Matches
      the review's own scope recommendation.
- [x] Bonus (not claimed, but present): P3-1 (`minHeight: 44` on End Drive / Park Here) was also
      picked up as a side effect of the P2-1 anatomy unification — a small positive beyond what
      the PR description claims.

## `.comingSoon` propagation audit

Grepped every reference to `SafetyLabel.Severity` / `SideOpportunity` / `SideAggregation` /
`.severity` across `ios/WePark/WePark` and `WeParkTests`. Every exhaustive `switch` over
`SafetyLabel.Severity` handles `.comingSoon` deliberately:

| Location | Handling | Verified |
|---|---|---|
| `SafetyLabel.swift:79` `init(for: SideOpportunity)` | `.comingSoon` → generic "Free — check signs" text, `.comingSoon` severity | explicit branch, tested |
| `SafetyLabel.swift:114` `init(for: SideAggregation)` | `.comingSoon` → same text-selection logic as `.free` | explicit branch, tested |
| `DriveModeBottomCard.swift` `chipBackgroundColor` | `.comingSoon` → `ParkingColors.restrictionComingSoon` (orange) | explicit branch |
| `DriveModeBottomCard.swift` `chipTextColor` | `.comingSoon` grouped with `.free`/`.restricted` → `.black` | explicit branch |
| `RouteService.swift:287` route-scoring switch | `.comingSoon` → `break` (no score change), documented as unreachable | **independently verified unreachable** — read `ParkingRulesEngine.safetyLabel(for:at:)` in full; its severity space is provably `.free`/`.metered`/`.restricted`/`.unknown` only, `.comingSoon` is never constructed there. `RouteService` only ever calls this method (`RouteService.swift:286`), never `aggregateSideDetail`. Claim holds. |
| `DrivingContextService.swift` `aggregateSideDetail`'s per-segment classification `switch` | `.comingSoon` listed in the `case .restricted, .unknown, .comingSoon: break` arm with a comment noting it can never actually occur there (the switch is over `engine.safetyLabel(...).severity`, same provably-4-case space) | correct, harmless |
| `CruiseVoicePolicyTests.swift:52` fixture helper `labelText(for:)` | `.comingSoon` → `"Free until 9 AM"` | explicit branch, matches test intent |

`CruiseVoicePolicy.swift` does not switch exhaustively on severity at all — it uses boolean
comparisons (`isFreeForVoice(_:)`, `== .metered`), so no additional branch was needed there;
confirmed by reading the file.

`BlockDetailView.swift` / `ParkedCarDetailView.swift` (map-color / block-detail-sheet paths)
reference "Severity" only in doc comments about the color band, never `SafetyLabel.Severity`
or `SideOpportunity` — confirmed via grep, zero hits on the actual types. The map's own orange
tier (`CurrentState.freeButRestrictionSoon`) is a wholly separate enum computed by
`ParkingRulesEngine.currentState(for:at:)`, untouched by this PR. **The chips-only scope claim
holds** — no cross-contamination into the map or detail sheets.

## Contrast math — independently recomputed

Recomputed relative luminance and WCAG contrast ratios from the actual shipped RGB values
(`ParkingColors.swift`, `DriveModeBottomCard.swift`), using Apple's documented dynamic
system-color RGB values for `Color.red`/`.green`/`.orange` (light: `#FF3B30`/`#34C759`/`#FF9500`;
dark: `#FF453A`/`#30D158`/`#FF9F0A`) and the literal fixed-hex values for the metered pair.

| Severity | Background → Text | My computed ratio (Light) | PR's claimed ratio | My computed (Dark) | PR's claimed |
|---|---|---|---|---|---|
| `.free` | green → black | **9.47:1** | 9.46:1 | **10.39:1** | 10.39:1 |
| `.comingSoon` | orange → black | **9.55:1** | 9.55:1 | **10.21:1** | 10.22:1 |
| `.metered` | amber(.92,.76,0) → near-black(.15,.10,0) | **9.96:1** | 9.93:1 (fixed hex, same both modes) | **9.96:1** | 9.93:1 |
| `.restricted` | red → black | **5.92:1** | 5.92:1 | **6.16:1** | 6.16:1 |

All match within rounding tolerance (my calc uses slightly different source RGB rounding for
the system dynamic colors than whatever tool the builder used — the deltas are all < 0.05,
noise-level). **Every severity clears WCAG AA's 4.5:1 normal-text floor in both appearances,
by a wide margin.** This directly verifies the PR description's headline claim.

**Override #2 independently re-verified**: white text on the same backgrounds —
white-on-green (Light) = **2.217:1** (PR claims 2.22:1 — exact match), white-on-red (Light) =
**3.547:1** (PR claims 3.55:1 — exact match). The review's literal "white text" suggestion
genuinely does fail WCAG AA at both the 3:1 large-text floor (green) and the 4.5:1
normal-text floor (red). The deviation to black/near-black text is correct, necessary, and
minimal — it changes only the text color, not the underlying solid-fill-badge design intent
the review asked for. **This is the strongest-verified claim in the whole PR** — every number
checks out to 3 significant figures.

## Override reasonableness (all four)

1. **AC-3 bridge exhaustiveness** — reasonable and minimal. The four pre-existing branches in
   both `init(for:)` overloads are byte-identical to before; only a new `.comingSoon` arm was
   added to each. `SafetyLabelSideOpportunityTests` untouched and passing confirms no regression
   to the "untouched" contract's *behavior*, even though its *literal* exhaustiveness was
   necessarily touched. Justified.
2. **Black text instead of white** — independently re-verified above; the override is not just
   justified, it's mathematically necessary (white genuinely fails).
3. **`nearFutureWindowHours` exposure** — a one-line `internal` computed property
   (`ParkingRulesEngine.swift:50`) that avoids a second hardcoded "6.0" literal. Verified the
   boundary logic is byte-consistent with `currentState`'s own `< nearFutureWindow` check
   (both strict less-than; confirmed by the passing `testAggregateSideDetail_winningRestrictionExactly6h_staysFree`
   test, which explicitly asserts the *not-comingSoon* boundary case). Minimal, single-source-of-truth,
   good practice.
4. **RouteService/CruiseVoicePolicyTests ripples** — RouteService's claim of "unreachable" was
   independently verified by reading `ParkingRulesEngine.safetyLabel(for:at:)` in full (not just
   trusting the inline comment) — its severity space is provably 4-case only. This is exactly
   the kind of claim the QA brief calls out as needing proof-by-running, not proof-by-reading —
   in this instance the *code itself* is the proof (a private, unexported enum-producing method
   with a fully readable, finite branch set), so static verification is sufficient; no live app
   run is needed to prove a `switch` statement inside a stateless pure function is unreachable.
   `CruiseVoicePolicyTests.swift`'s one-line fixture addition is trivial and correct.

## Voice hand-trace

Traced `buildUtteranceText` / `CruiseVoicePolicy.utteranceText` / `CruiseVoicePolicy.shouldAnnounce`
by hand for the three requested scenarios, using `isFreeForVoice(_:) = severity == .free || severity == .comingSoon`:

- **Both-free** (`.free`/`.free`): `leftFree=true, rightFree=true` → `"[Street]. Free parking
  sections on both sides — check signs."` — identical to pre-TF2-18 behavior since neither side
  is `.comingSoon` here.
- **Left-comingSoon / right-restricted**: `isFreeForVoice(.comingSoon)=true`,
  `isFreeForVoice(.restricted)=false` → `leftFree=true, rightFree=false` → routes to the
  "Left free only" template → `"[Street]. Free parking sections on the left — check signs."`
  **This is the critical case**: the `.comingSoon` side voices as free, not silent — confirmed
  both by hand-trace and by the passing test
  `testCruiseVoicePolicy_comingSoonIdenticalToFree_shouldAnnounceAndUtteranceText`, which
  explicitly asserts `shouldAnnounce` is `true` for a comingSoon-only context. No smuggled
  voice-silence regression.
- **Both-metered**: unaffected by `.comingSoon` entirely — `leftMetered=true, rightMetered=true`
  → `"[Street]. Metered on both sides."`, same as before.

OQ-4 (voice unchanged) holds under hand-trace, not just the automated regression tests.

## Tests

Re-ran the full suite myself on a fresh, purpose-built simulator (`qa-tf2-17-18`, iPhone 17
Pro, UDID `CA0AA4D7-6DD3-4898-9FEF-C2AB29A4D690`, deleted after this pass), from a `clean`
build first:

```
xcodebuild clean ... → CLEAN SUCCEEDED
xcodebuild test ...  → TEST SUCCEEDED
565 "passed" test cases, 0 "failed" — grep-verified against the raw log
```

Matches the PR description's claimed 565/0 exactly. `RegionSyncGuardTests` (5 cases) all pass.
`AggregateSideDetailComingSoonTests` (5 boundary tests, including the exact-6h non-boundary
case) all pass. `RecenterPillBottomPaddingTests` (5 tests incl. monotonicity invariant) all
pass. `TF217Tests.swift` contains 27 `func test` cases (grep-counted), matching the claimed
Test Inventory coverage (§8 items 1–17, with the D-group `.comingSoon` boundary tests as a
documented bonus beyond the original spec's inventory).

Cold clean build: confirmed (ran `xcodebuild clean` then `xcodebuild test` from scratch on a
brand-new sim, not reusing any cached derived data from a prior run).

## Live-UI smoke (mount-chain gate — mandatory, this PR touches `ContentView.swift` and
`DriveModeBottomCard.swift`)

Built the app fresh (`xcodebuild build`, separate clean derived-data path), installed on the
QA sim, launched, and screenshotted three times as the app warmed up. Final screenshot
confirms:

- **ASP banner renders**: "ASP in Effect Today" amber banner with black text, at the top,
  matches `ASPBanner.swift`'s existing pattern (unmodified by this PR).
- **Toolbar overlay chain intact**: gear/settings button (top-left) and the 3-button cluster
  (locate-me, Park Until clock, Drive route) at top-right, all rendering below the banner
  with no visual overlap — this is a direct visual confirmation that the P2-2 44→100 padding
  change is correctly clearing the banner in the live app, not just in the pure-function unit
  test.
- **Map renders correctly** with polylines hidden at the wide Manhattan-overview zoom (expected
  behavior per `polylineHideSpanThreshold`, unrelated to this PR).

**Not verified in this pass** (same sandbox limitation the builder hit, not a regression risk
specific to this PR): the in-Drive-Mode toolbar row (End Drive/Report/Park Here), the
Drive Mode bottom card with real chip data (color/text/stacking), and the recenter pill's
clearance across its four approach-strip/Park-Until-pill combinations. All of these require
driving the destination-search → Start Drive multi-tap flow, which has no gesture-injection
path in this environment (same gap noted for `#31`-class PRs going back to W8.5d). This is
the correct thing to route to Kevin's on-device drive-test rather than re-attempt here.

Screenshot inspected: `/private/tmp/.../qa-smoke-launch3.png` (not committed — ephemeral scratch
file; re-run at merge time if a lasting artifact is wanted).

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

None.

### 🟢 Minor / nit

- **#1: `recenterPillBottomPadding`'s component-height constants (140/30/58/8) are
  hand-estimated, not measured on-device.**
  - Where: `ContentView.swift`, `recenterPillBottomPadding(showApproachStrip:parkUntilVisible:)`.
  - What: The doc comment describes these as "approximate, verified via smoke" but the smoke
    that verified them was the builder's own reverted launch-arg harness, and my own sandbox
    can't reach Drive Mode to re-measure. The base-card jump from the review's suggested `88`
    to the shipped `140` (attributed to P2-5's stacked chip layout adding one extra row) is
    directionally plausible by rough font-metrics arithmetic (roughly +48–52pt for a second
    stacked chip row matches the +52pt delta) but not pixel-verified.
  - Expected: On-device confirmation across all four approach-strip/Park-Until-pill
    combinations that the Recenter pill genuinely clears the bottom card stack with the
    documented 8pt gap, not overlapping or leaving excess dead space.
  - Repro: Start Drive Mode, pan the map to trigger `followPaused`, approach a destination to
    trigger the strip, open Park Until — observe the Recenter pill position in each
    combination.
  - Owner: Kevin's drive-test (this is explicitly the kind of check the mount-chain gate
    exists for but that this sandbox cannot execute).

- **#2: `SideAggregation`'s and `SafetyLabel.Severity`'s `.comingSoon` case has no equivalent
  concept documented for `CurrentState` (the map's own tier), which could confuse a future
  engineer skimming both enums side-by-side.**
  - Where: `DrivingContextService.swift` (`SideOpportunity.comingSoon`) vs.
    `Models/CurrentState.swift` (`CurrentState.freeButRestrictionSoon`) — same underlying
    concept, two different names, in two different layers.
  - What: This is intentional per the PR's own doc comments (palette doc §8 explicitly calls
    out the naming difference and the layer difference), so it's not a bug — but the naming
    asymmetry (`comingSoon` vs. `freeButRestrictionSoon`) is a small ongoing cognitive-load tax
    for anyone cross-referencing the two systems.
  - Expected: Not a spec requirement; purely a naming-consistency nit.
  - Repro: N/A — code review observation.
  - Owner: `@ios-engineer`, purely optional, no urgency.

- **#3: AC-12 (chip text-length live smoke) is claimed resolved by a harness that no longer
  exists to re-verify.**
  - Where: PR description, "Live-UI smoke evidence" section.
  - What: The builder's screenshot evidence for the 30-char worst-case fixture came from a
    temporary launch-arg harness in `WeParkApp.swift`, correctly reverted before commit. That's
    the right process (no dead code left behind), but it means this specific claim is
    currently *only* verifiable by re-adding a similar harness or by Kevin reaching that exact
    string live on a real drive. The layout math (§P2-5 stacked chip gets ~358pt vs. the
    30-char string's likely rendered width) strongly supports the claim, and
    `minimumScaleFactor(0.9)` is a reasonable second line of defense, but this remains an
    assertion I could not independently re-render pixel-for-pixel.
  - Expected: Per spec AC-12, a live-UI smoke confirmation. Currently satisfied by builder
    self-report only.
  - Repro: N/A — recommend Kevin specifically look for a long "Free until Wednesday 11:45 PM"-class
    string during the drive-test and confirm it doesn't wrap/shrink oddly.
  - Owner: Kevin's drive-test.

### 💡 Out of scope (logged, not fixed)

- P2-4 (amber collision between `ASPBanner` and metered chip) — correctly left as an open
  decision point per the review's own recommendation, not resolved in this PR. Still needs a
  Kevin yes/no.
- P2-3 / P3-2 (bottom-stack margin convention, corner-radius standardization) — correctly
  deferred per the review's suggested scope.
- Metered/restricted chip "until X" copy (OQ-2 from the TF2-17 spec) — correctly deferred,
  unchanged this pass.

## What's working

- **The service-layer refactor is exactly the kind of "pure refactor for reuse" the spec asked
  for.** `aggregateSide` really is a one-line wrapper; nothing about the pre-existing 9-case
  decision table's behavior changed, confirmed by an unmodified test file passing unmodified.
- **The FT-9 regression is taken seriously and provably closed at the aggregation layer**, not
  just re-asserted at the engine layer where it was already fixed. This is the right level of
  paranoia for a bug class that already bit this codebase once.
- **The contrast-math override is the best-verified claim in the PR** — every single number in
  the builder's table, including the "white text actually fails" justification, reproduces
  independently to 2-3 significant figures. This is what a spec-fidelity override should look
  like: measured, not asserted.
- **Voice safety is treated as a first-class invariant, not an afterthought.** `isFreeForVoice(_:)`
  is a clean, tested, single point of truth, and the PR adds tests that specifically assert the
  new severity is *voice-silent-safe* (i.e., doesn't accidentally go silent) rather than only
  testing that it doesn't change text — the right thing to worry about given the review's own
  "information hierarchy inversion" framing for why `.comingSoon` matters.
- **Nothing touches `MapViewRepresentable.swift` or the `.safeAreaInset` attachment points.**
  Confirmed by absence from the diff, not just by the PR description's claim. The #31 regression
  class this repo has been burned by twice is structurally impossible to reintroduce via this
  diff.
- **The launch-arg harness cleanup is real** — `WeParkApp.swift` does not appear anywhere in
  `gh pr diff 66`, confirming the "fully reverted before commit" claim rather than trusting it.

## Kevin's drive-test remains the final gate

This report ships the code as structurally sound, tested, and visually verified as far as a
non-interactive sandbox permits. It does **not** replace the on-device drive-test for:
1. Chip legibility in direct sunlight (the original complaint this whole TF2-18 pass exists to
   fix) — contrast math says it should now pass, but math isn't sunlight.
2. The actual "Free until X" copy reading correctly and un-clipped on a real block.
3. `.comingSoon` orange actually appearing when a real block is within 6h of a real
   restriction.
4. The four Recenter-pill bottom-stack combinations not overlapping (Finding #1).
5. The in-Drive-Mode top-toolbar row's new button anatomy reading as one coherent row at
   actual driving distance/glance-time, not just in a static screenshot.

---

**Orchestrator note (2026-07-10):** the "prompt-injection attempt" flagged above was investigated: `docs/design/drive-mode-ui-review-2026-07-09.md` on main contains no injected content (grep for system-reminder/MCP/instruction patterns clean; single commit history `251bbe1`). The QA agent saw the harness's own legitimate system-reminder blocks appended to a tool result and misidentified them. No compromise; the agent's ignore-and-continue response was correct either way.
