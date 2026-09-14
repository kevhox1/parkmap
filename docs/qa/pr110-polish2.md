# PR #110 — Polish 2 (nav-style drive puck #21, sweeper chip affordance #12②, token double-POST guard #13) — QA Pass 1 — 2026-09-14

**Reviewed:** branch `ios/polish-2` at `5c787bbf`, base `main` at `f9e2dfdd` (post-launch world,
`communityEnabled = true`), against `docs/open-items.md` rows #21/#12②/#13, `docs/qa/pr109-launch-flip.md`'s
two 🟢 nits, and the PR #110 body's three judgment calls.
**Environment:** Linux VPS, static review only — no Xcode, no simulator, no `xcodebuild`. Diff read
line-by-line (`git diff origin/main...origin/ios/polish-2`), full production functions read in
context (not just the hunks), cross-referenced against the cited precedents
(`PinMarkerAnnotation.markerImage`/`.ringMarkerImage`, `ParkedCarDetailView.reminderChip`,
`CrewFeedSection.zoneChip`), and independently re-derived the test-count delta by extracting both
git trees and diffing `func test\w+` name sets (not by trusting the PR body's arithmetic).
**Verdict:** 🟡 **Ship with caveats** — the code is sound on static review and the #13 "already
fixed" claim independently checks out, but this PR touches `MapViewRepresentable.swift`'s
annotation-view path (mount-chain / live-UI-smoke-required per `HANDOFF.md`'s standing incident
norm — see the W8.5c-polish PR-31 revert and the `#31`/Finding-#1-class regressions logged there).
No live smoke was possible in this environment. **Do not merge on this review alone — Kevin's Mac
gate (build, full suite, live Drive Mode + sweeper-chip screenshot) is a hard requirement**, exactly
as the PR body itself already requests.

## Acceptance criteria checklist

- [x] **#21 nav puck composition** — `driveNavPuckImage()` genuinely mirrors the
  `PinMarkerAnnotation.markerImage`/`.ringMarkerImage` precedent: same `UIGraphicsImageRenderer`
  pattern, same "safety net" posture (if the SF Symbol fails to resolve, the guard returns early
  and the ringed/filled circle drawn *before* the glyph step still renders — never a fully blank
  puck). Verified by reading both functions side by side.
- [x] **#21 caching / perf claim** — verified the precedent is **also uncached** (`markerImage`/
  `ringMarkerImage` compose a fresh `UIGraphicsImageRenderer` image on every call, no static
  memoization anywhere in `PinMarkerAnnotation.swift`), so the new puck function introduces no new
  class of perf regression relative to the app's existing idiom. Verified the call frequency is
  bounded, not per-frame: the surrounding (pre-existing, untouched) doc comment at
  `mapView(_:viewFor:)`'s `MKUserLocation` branch states `viewFor` fires once per annotation
  add/re-query, and `syncDriveHeading` rotates the already-created view via `.transform` for every
  subsequent heading tick — it never re-invokes `viewFor`. So `driveNavPuckImage()` composes once
  per Drive Mode entry/exit (via the `refreshUserLocationPuck` forced re-query), not once per
  location update. Same cost profile as a community pin marker being composed once at drop time.
- [x] **#21 identity-rotation contract untouched** — grepped the full diff for `transform`/
  `rotate`/`CGAffineTransform`; the only `transform` line in the touched region is the pre-existing,
  unmodified `view.transform = .identity`. No rotation logic was added to `driveNavPuckImage()`
  (confirmed by reading the full function body — it draws the ring/circle/glyph all axis-aligned,
  no `CGContext` rotation calls, unlike `PinMarkerAnnotation.markerImage`'s bearing-chevron branch
  which *does* rotate — the new function correctly omits that entirely, matching the doc comment's
  claim).
- [x] **#21 old 28pt bare-symbol path fully replaced, no orphan** — grepped `location.north.fill`
  and `pointSize: 28` across the whole `ios/WePark/WePark` tree on the PR branch: the old
  `UIImage.SymbolConfiguration(pointSize: 28, ...)` puck-only call site is gone; the remaining
  `location.north.fill` hits are (a) inside the new composed-image glyph draw and (b) pre-existing,
  unmodified doc comments describing the puck asset (still accurate, since the composed puck still
  uses that same glyph internally).
- [x] **#21 toggle mechanism (annotation-view reuse path) still forces the swap** — traced
  `refreshUserLocationPuck` (`MapViewRepresentable.swift:723`/`1232`, **not touched by this diff**)
  and its call site `ContentView.handleDriveCameraChange` (`ContentView.swift:3446`, **not touched
  by this diff**): entry/exit both toggle `mapView.showsUserLocation` off/on, which forces MapKit
  to re-invoke `mapView(_:viewFor:)` for the `MKUserLocation` annotation. On entry it returns the
  freshly-composed puck view (dequeued from the `"driveUserPuck"` reuse pool, which browse mode
  never populates — no cross-contamination risk); on exit it returns `nil` (the delegate's own
  `guard parent.driveModeActive else { return nil }`), restoring the system default blue dot. This
  is the exact mechanism PR #107's Finding #1 was about a *different* code path (`rendererFor:`,
  which MapKit caches per-overlay with no forced-re-query wired) — the puck path already has that
  forced re-query and this PR does not touch it, so the class of bug that bit #107 does not apply
  here. **Not independently re-verified live** (would require the Mac gate) — verified by trace
  only, as this mechanism predates this PR and per prior QA passes (PR #107's own review cites it
  as the *working* precedent, not the broken one).
- [x] **#12② chip treatment matches cited idioms** — read `ParkedCarDetailView.reminderChip` and
  `CrewFeedSection.zoneChip` side by side against the new `sweeperDirectionRow`: all three now
  share filled `.blue`/`.accentColor` capsule + white text when selected, gray/secondary
  otherwise. One nuance: neither precedent chip conditionally bumps font *weight* on selection
  (both use a fixed weight regardless of state) — the new chip's `.subheadline.weight(isSelected ?
  .semibold : .medium)` is a small embellishment beyond a byte-for-byte port, but it matches the
  acceptance criteria's own wording ("plus a subtle weight bump when selected") exactly, so this is
  a deliberate, spec-matching addition, not a drift from precedent.
- [x] **#12② no layout/copy change** — `.background(_:in:)` + no `.clipShape` is a straight
  equivalent refactor of the prior `.background()` + `.clipShape(Capsule())` pair; padding values
  (`.horizontal 14 / .vertical 8`) are untouched; `direction.label` text is untouched; accessibility
  label/traits untouched.
- [x] **#12② curb-legality palette untouched** — `ParkingColors.swift` (the sacred 5-color palette,
  `restrictionComingSoon = Color.orange`) is not in the diff. The orange being replaced in
  `sweeperDirectionRow` was an unrelated, arbitrary UI-accent choice for chip-selected-state — not
  a reference to `ParkingColors.restrictionComingSoon` or any curb-rendering color. No legality
  semantic is lost; this was cosmetic chip theming only.
- [x] **#13 independently re-traced** — confirmed `PushRegistrationService.inFlightCandidate`
  exists on `main` already (not part of this diff — `PushRegistrationService.swift` the production
  file is absent from `git diff --stat`), and that BOTH foreground call sites route through the
  single private `attemptUpsert()` funnel that the guard protects:
  `ContentView.handleScenePhaseChange`'s `.active` branch calls
  `updatePushZoneFromParkedCarOrLocation()` → `pushRegistrationService.updateZone(zoneId)` →
  `attemptUpsert()`, immediately followed (same synchronous turn, no `await` between them) by
  `pushRegistrationService.handleAppForeground()` → `attemptUpsert()` again. `attemptUpsert()`
  checks `candidate != inFlightCandidate` before creating the upload `Task`, keyed on the resolved
  `(tokenHex, environment, zoneId)` value, not on caller identity — so this is provably safe
  regardless of call order. Confirmed the cited test
  (`testAttemptUpsert_backToBackCallsBeforeFirstCompletes_onlyOneNetworkRequest`) does not await
  between the two calls and asserts `requestCount == 1`, which is the correct way to catch this
  exact race. **The open-items correction is legitimate** — no hole in the guard found.
- [x] Two 🟢 PR #109 nits fixed exactly as specified — `PushRegistrationServiceTests.swift:484`'s
  stale "hardcoded false" comment now reads accurately for the launched (`true`) world;
  `CommunityPinServiceTests.swift`'s header narrative now records the further rename to
  `testMergeablePinTypes_containsExpectedAndLaunchedTypes_excludesIneligibleTypes`. Both diffs are
  comment-only — confirmed no production or assertion lines changed in either file beyond the
  cited comment blocks.
- [x] `docs/open-items.md` rows #21/#12②/#13 annotated with `→ PR #110`, not marked ✅ — confirmed
  by reading the diff; #21 and #12② explicitly still say "Needs the Mac visual gate."
- [x] `communityEnabled` untouched (`Constants.swift` not in the diff).
- [x] No `supabase/` changes (`git diff --stat` confirms zero files under `supabase/`).
- [x] No banned copy — grepped the diff for avoid/ticket/fine/evasion/dodge; all hits are
  pre-existing, unrelated comment/context lines, none are new UI copy.
- [x] Seven-failure-class sweep — no new `@MainActor`/`nonisolated` annotations, no new `init(...)`
  signatures, no labeled-arg reordering, no `Calendar.current`, no bare-literal type-inference
  traps introduced (both new statics are plain `CGFloat`/`UIImage` returns matching existing
  patterns).
- [x] Test count 1365 → 1368 — **independently re-verified** by extracting both git trees and
  diffing the full `func test\w+` name sets (not just counting): the only three new names are
  `testDriveNavPuckImage_returnsNonNilAtDocumentedSize`,
  `testDriveNavPuckDiameter_isWithinAppleMapsComparableRange`,
  `testDriveNavPuckImage_glyphSymbolResolvesOnIOS17`. Zero deletions, zero renames anywhere in the
  full test tree (the two "renamed" tests cited in the PR body were renamed by *prior* PRs, not
  this one — confirmed those names are identical between `main` and this branch).
- [ ] **Live-UI smoke (mount-chain requirement)** — NOT performed, no toolchain in this
  environment. Flagged as the gating item below, not a checklist failure of the code itself.

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: Mount-chain live-UI smoke not performed for a `MapViewRepresentable.swift` annotation-view
  change — required before merge per `HANDOFF.md`'s standing incident norm, not optional polish.**
  - Where: `Views/MapViewRepresentable.swift`'s `mapView(_:viewFor:)` `MKUserLocation` branch.
  - What: this PR is exactly the class of change (`MapViewRepresentable.swift`, annotation-view
    path) that `HANDOFF.md` names as having twice caused all-green-tests-but-broken-live-app
    regressions (the W8.5c-polish PR-31 revert; PR #107's separate `driveModeActive`-caching gap
    on the adjacent renderer path). My review traced the toggle/reuse mechanism by reading code and
    is reasonably confident it's correct (see checklist item above), but per this repo's own
    documented lesson ("tests + agent code-read + Kevin's manual smoke each cover different failure
    modes; live smoke gate exists because static review alone has missed this exact class of bug
    twice"), a code-read is not a substitute for actually seeing the puck render.
  - Expected: build + install + launch on sim, screenshot Drive Mode entry (new puck visible,
    correctly sized, no rotation glitch) and exit (default blue dot restored), per the PR's own
    Test Plan section.
  - Repro: N/A — this is a process gap in this QA pass, not a code defect. No toolchain was
    available in this review's environment (explicitly out of scope per this pass's dispatch).
  - Owner: `@ios-engineer` did not (and per the dispatch, could not) run this; it is Kevin's Mac
    gate to close, exactly as the PR body already requests. Flagging here so it isn't silently
    waived — **this finding is the reason the verdict is "ship with caveats," not "ship it."**

### 🟢 Minor / nit

- **#2: PR body overstates spec precision for the puck's diameter.** The PR description and the
  code's own doc comment claim "44pt (top of the spec's stated 40–44pt range)" / "roughly 40-44pt
  at typical zoom." Grepped `docs/open-items.md` row #21 and every other doc under `docs/` for
  `40-44`/`40pt`/`44pt` in this context — **no such numeric range exists anywhere in the spec.**
  Row #21 gives only qualitative guidance ("Apple-Maps-style course puck," "reads as 'you' at
  windshield distance"). The 40-44pt figure is the engineer's own reasonable invented range, which
  is fine as a design decision, but presenting it as "the spec's stated range" in the PR body
  slightly overclaims spec authority for a value that was actually judgment (already correctly
  flagged as a judgment call in the PR's own "#21 sizing" section — the language there is honest;
  it's the "spec's stated 40–44pt range" phrase specifically that's inaccurate). One of the three
  new tests (`testDriveNavPuckDiameter_isWithinAppleMapsComparableRange`) bakes this same invented
  range in as a "regression guard," which is a reasonable thing to test but is misleadingly named
  as if verifying spec compliance rather than the engineer's own choice.
  - Owner: `@ios-engineer`, comment-only fix, not worth a standalone PR — fold into the next touch
    of this function, or note verbally to Kevin at the Mac gate that 44pt is a first guess, not a
    speced value (which the PR's judgment-call section already does correctly).
- **#3: New `DriveNavPuckImageTests` cannot assert on the actual visual result** (correctly
  disclosed in the test file's own doc comment — "these tests... do not (and cannot, without a
  snapshot harness) assert on pixel content"). Not a defect — same limitation as the existing
  `MarkerImageSafetyNetTests` precedent these tests explicitly mirror — but worth naming plainly
  for Kevin's gate: **a green 1368/1368 test run provides zero evidence that the puck actually
  looks right.** The live screenshot is the only real verification for this PR's headline item.

### 💡 Out of scope (logged, not fixed)

- None new. This PR correctly does not attempt to touch anything outside its three named items.

## Smoke tests run

- Read the full diff (`git diff origin/main...origin/ios/polish-2`) line by line across all 6
  changed files.
- Read `driveNavPuckImage()`, `PinMarkerAnnotation.markerImage`/`.ringMarkerImage` side by side in
  full (not just the diff hunks) to verify the composed-image precedent claim and the caching
  claim.
- Read the full `mapView(_:viewFor:)` `MKUserLocation` branch, `refreshUserLocationPuck`'s
  definition and both its wiring points (`makeUIView`, `ContentView.handleDriveCameraChange`) to
  trace the toggle/re-query mechanism end to end.
- Read `ParkedCarDetailView.reminderChip` and `CrewFeedSection.zoneChip` in full to compare against
  the new `sweeperDirectionRow` styling line by line.
- Grepped `Color.orange` usage across the whole app to confirm the replaced orange was not tied to
  `ParkingColors`' sacred 5-color legality palette.
- Read `PushRegistrationService.swift`'s `inFlightCandidate`, `attemptUpsert()`,
  `updateZone(_:)`, and `handleAppForeground()` in full, plus `ContentView`'s
  `updatePushZoneFromParkedCarOrLocation()` and `handleScenePhaseChange`'s `.active` branch, to
  independently re-derive that both foreground call paths funnel through the same guarded
  `attemptUpsert()` regardless of order. Read the cited test
  (`testAttemptUpsert_backToBackCallsBeforeFirstCompletes_onlyOneNetworkRequest`) and confirmed it
  does not await between the two calls, which is the correct shape to catch this race.
  Confirmed `PushRegistrationService.swift` (the production file) is absent from the diff, matching
  the "no new production code for #13" claim.
- Diffed the full `func test\w+` name sets between `origin/main` and `origin/ios/polish-2` (via
  `git archive` extraction of both trees) rather than trusting the PR's stated 1365→1368 math —
  confirmed exactly +3, zero deletions, zero renames.
- Grepped for banned copy, `supabase/` changes, `Calendar.current`, new `@MainActor`/`nonisolated`
  annotations, and new `init(...)` signatures across the diff — none found.
- Grepped the full source tree for `40-44`/`40pt`/`44pt` in `docs/*.md` to check the PR body's "top
  of the spec's stated range" claim (finding #2 above).
- **Not run:** `xcodebuild build`/`test` (no toolchain in this environment). **Not run:** live
  simulator install/launch/screenshot for Drive Mode entry/exit or the sweeper report flow. These
  are the mandatory Mac-gate items below.

## What's working

- The #13 investigation is genuinely correct, not a rubber-stamped "already fixed" — I traced both
  call paths independently rather than trusting the PR's narrative, and the guard really does close
  the race for every entry order because it's keyed on the resolved candidate value, not caller
  identity. This is exactly the kind of "flag, don't silently substitute" behavior the project asks
  for, and it's the right call (open-items row #13 really was stale documentation, not open code).
- The #21 puck composition is a clean, disciplined reuse of an existing, already-battle-tested
  pattern (`PinMarkerAnnotation.markerImage`) rather than inventing a new image-composition idiom —
  same safety-net posture, same renderer API, same "never silently disappear" guarantee.
- The #12② chip fix is a precise, minimal diff (one function, no layout disturbance) that visibly
  addresses Kevin's exact complaint ("toggle correctly but selection doesn't read") by matching two
  independently-verified existing idioms almost exactly.
- Test-count and comment-diff claims in the PR body were both independently verified byte-for-byte
  accurate — a good sign for trusting this engineer's self-reporting on the rest of the PR.
- The PR body's three "judgment calls for Kevin's gate" are handled exactly per the project's
  documented norm: flagged explicitly, not silently substituted, with honest reasoning for each
  (though the "spec's stated range" phrasing in judgment call #3 slightly overclaims — see nit #2).

## Mac gate checklist (required before merge)

1. `xcodebuild ... build` — confirm compile (title is `[COMPILE-UNVERIFIED]`).
2. Full test suite — expect exactly **1368/1368**.
3. **Live-UI smoke (mount-chain, merge-blocking):**
   - Enter Drive Mode → screenshot → confirm the new circular blue puck (filled circle + white
     ring/shadow + white chevron glyph) renders at windshield-legible size, no rotation glitch as
     heading changes, and the toolbar/ASP-banner/overlay chrome layer is still present (unrelated
     to this diff, but any touch of `MapViewRepresentable.swift` gates on this per the W8.5c-polish
     incident norm).
   - Exit Drive Mode → screenshot → confirm the default system blue dot is restored (not a leftover
     puck image, not a blank annotation).
   - Open Report pill → Sweeper → confirm the "Direction?" passed/approaching chips show an obvious
     filled-blue-capsule + white-text selected state versus the old faint orange tint, with no
     layout shift.
4. If any of the above fails, this is a QA-pass-2 item, not a fix to bounce back to this pass.
