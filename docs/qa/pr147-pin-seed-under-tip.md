# PR #147 QA Pass 1 — pin-seed-under-tip — 2026-10-26

**Reviewed:** branch `fix/pin-seed-under-tip` at `92a285a2`, against Kevin's smoke report
("pin lands mid-building, tens of metres off") and the orchestrator's ruling accepting
`setRegion` as a deliberate deviation from the "single `setCamera`" entry invariant.
**CI:** green, run `40261968752`, 2009/2009, confirmed against this exact head SHA
(`gh run view --json headSha` matches `92a285a2`).
**Verdict:** MERGE

## Summary

The fix is logically sound and strictly better than the code it replaces: the entry camera
now derives an exact `MKCoordinateRegion` instead of an altitude guess, the seed-under-tip
math cancels to precisely 0.40 under hand re-derivation (not just the new test's say-so), and
the `force==true`/`force==false` asymmetry that skipped the old correction nudge is
structurally gone — both paths now funnel through the same `settleWithoutNudge()`. Diff is
genuinely minimal (3 files, confined to the policy/controller/tests triad) and flag-off is
inert. One thing does not add up: the commit's own math (~5% altitude error × the 0.1
height-fraction offset) accounts for roughly 1-2m of drift, not the reported tens-of-metres/
mid-building miss — the root-cause narrative is incomplete, though the fix itself is sound
regardless of which exact mechanism was dominant. No toolchain is available in this review
environment (Linux sandbox, no Xcode/xcrun) so live-UI smoke could not be performed; this PR
does not touch any of the mandatory-live-smoke mount-chain files, and the feature flag
(`curbPinPlacementEnabled`) is off in `Constants.swift` today, so a sim build would not have
exercised this code path regardless.

## Acceptance criteria checklist

- [x] Entry camera uses an exact `MKCoordinateRegion`, no `altitudeForSpan` FOV guess in the
  entry path — verified by reading `begin()`; `altitudeForSpan`/`entryDistance` are still
  computed but now feed only the soft pinch-zoom range (floor/ceiling), not the rendered
  position.
- [x] Seed lands at exactly the 40% tip fraction, independent of screen size/seed latitude —
  verified by hand-deriving `entryCenter` + `entrySpanDegrees`'s algebra (see "What's
  working" below); the derivation cancels to exactly `tipHeightFraction` because both
  functions reference the identical `metersPerDegreeLatitude` constant. Also checked the new
  test (`testEntryRegion_seedLandsExactlyAtTheTipFraction_acrossScreenSizes`) reaches the same
  conclusion independently.
- [x] The `force==false`-only nudge asymmetry is removed, not just patched — verified by
  reading `finishEntry`: the old `performNudge`/`settleWithoutNudge` branch on `!force` is
  gone; both force paths now call `settleWithoutNudge()` unconditionally.
- [ ] Root-cause explanation accounts for the reported magnitude of the bug (~20-30m / mid-
  building) — FAILED to fully verify. See Finding #1. The fix is still correct; the stated
  *why it was that big* does not check out by the numbers in the commit message itself.
- [x] No other caller of the deleted nudge path is broken — verified: `focus(on:)` and
  `cycleNearbyCurb()` still call `CurbPlacementMapPolicy.settleNudge`/`performNudge` unchanged
  (confirmed via diff: only the two hunks inside `begin()` and `finishEntry()` touch nudge
  logic).
- [x] Exit path unchanged — verified via `git diff fb5b2764 92a285a2 -- CurbPlacementController.swift`;
  `end(restore:)` has zero diff hunks; still `setCamera` for pitch/heading restoration.
- [x] Resolve loop (`tick`/`resolve`/`absorb`) untouched — verified, no diff hunks in that
  region of the file.
- [x] Flag-off / nil-index inert — verified: `AppConstants.curbPinPlacementEnabled = false` in
  `Constants.swift` today; `CurbPlacementController` is only constructed from
  `CurbPlacementPolicy.routing`'s `.placement` branch, which requires `flagEnabled`.
- [x] Six known Swift compile-failure classes checked against the diff — no hits (argument
  order, memberwise-init order, and nonisolated-on-the-whole-enum convention all line up); CI
  green on the exact head SHA corroborates.
- [x] New/updated tests are real, not rubber-stamped — verified by hand-recomputing
  `testEntrySpanDegrees_isExactWithNoFieldOfViewApproximation`,
  `testClampedVisibleWidthMeters_keepsTheBoundsAspectRatio`, and the cross-screen-size round
  trip; all check out. Minor nit on the stale-callback test, see Finding #3.
- [ ] `setRegion`'s aspect-fit + ambient-look-pitched entry verified live on device — NOT
  VERIFIED. No Xcode/simulator toolchain in this review environment; the PR's own
  `[COMPILE-UNVERIFIED]` tag on this exact concern is accurate. See Finding #2 for why it's
  not a merge blocker today.

## Findings

### 🟡 Significant

- **#1: The root-cause magnitude claim doesn't check out by the numbers in the commit message**
  - Where: `CurbPlacementMapPolicy.swift:207-220` (doc comment), commit message body.
  - What: The commit attributes the "tens of metres / mid-building" miss to `altitudeForSpan`'s
    "~5% accurate" FOV guess plus the `force==true`-skips-the-nudge asymmetry. Re-deriving the
    actual geometry: the south offset baked into `entryCenter` is
    `(0.5 - 0.40) * visibleHeightMeters = 0.1 * ~238m ≈ 23.8m`. A 5% error in the *altitude*
    that feeds the ACTUAL rendered height (not the assumed one) propagates into the seed's
    apparent tip-fraction as `0.1 * 0.05 * 238m ≈ 1.2m` of vertical drift — nowhere close to a
    "mid-building" miss on a typical ~5-15m building setback, let alone 20-30m. Either (a) the
    real-world FOV error of `altitudeForSpan` is far larger than the documented "~5%" (plausible
    — it's explicitly flagged "never verified on a real device" in that function's own doc
    comment), or (b) a second mechanism was doing most of the damage: the OLD `entryArrived`
    checked only `currentDistance`/`currentPitch`, never the camera's actual center — so a
    `regionDidChangeAnimated` callback could in principle report "arrived" while pitch and
    distance happen to be near target but the center pan is still mid-flight, triggering the old
    nudge-or-settle branch against a transient, not-yet-landed camera state. The NEW
    `entryArrived` (center-distance-based, 3m tolerance) closes that second gap too, whether or
    not it was the dominant one — but the commit doesn't credit it, and nobody has independently
    confirmed which mechanism actually produced the reported magnitude.
  - Expected: a root-cause writeup whose arithmetic explains the reported symptom, or an
    explicit "the exact size is unconfirmed, here's the range" caveat.
  - Repro: re-derive `0.1 * visibleHeightMeters * altitudeForSpan's actual measured error` using
    Kevin's original repro coordinates/altitude once he's back on his Mac, and compare the
    pre-fix pin position to post-fix, to confirm the fix actually closes the gap he saw (not
    just that the new math is internally exact).
  - Owner: `@ios-engineer` (confirm/amend the root-cause doc comment once Kevin reports back
    from the Mac smoke, not a pre-merge blocker).

- **#2: Ambient-driving-look pitched entry into placement is untested and only accidentally inert**
  - Where: `CurbPlacementController.swift:241` (`mapView.setRegion(region, animated: animate)`,
    `[COMPILE-UNVERIFIED]` comment on the line above); `ContentView.swift:6098`
    (`handleLongPress`'s guard: `!driveModeActive, !blockSelectModeActive` — does **not**
    exclude the ambient driving look); `AmbientDrivingLook.swift:93-95`
    (`isInEffect = driveModeDefaultEnabled && !driveModeActive` — the ambient look **is** the
    resting posture, independent of `driveModeActive`).
  - What: Once `AppConstants.driveModeDefaultEnabled` ships `true`, a user can long-press into
    curb placement directly from the ambient look's pitched (~30°), home-camera posture. The
    entry `setRegion` call simultaneously flattens pitch to 0 AND pans to the new center in one
    animated transition. Whether MapKit renders that as one smooth move or an ugly
    flatten-then-snap compound is explicitly unverified — the author flagged it with
    `[COMPILE-UNVERIFIED]` and "Mac smoke: confirm a session started from a tilted camera ...
    lands fully flat, not merely re-centred," which is an honest admission, not a silent gap.
  - Expected: this transition is checked live before `driveModeDefaultEnabled` flips to `true`
    in production, since curb placement's long-press guard does not block entry from the
    ambient look.
  - Repro (today): inert — `AppConstants.driveModeDefaultEnabled = false` and
    `AppConstants.curbPinPlacementEnabled = false` in `Constants.swift`; neither this PR nor any
    shipped build can currently reach this combination.
  - Owner: `@ios-engineer` — add to the pre-flight checklist for whichever PR flips
    `driveModeDefaultEnabled` to `true`; not a blocker for #147 itself.

### 🟢 Minor / nit

- **#3: `testEntryArrived_staleCallbackFromAnInterruptedAnimationIsRejected`'s first assertion conflates two gates**
  - Where: `CurbPlacementMapPolicyTests.swift` (the `farAway`/pitch-30 assertion).
  - What: `XCTAssertFalse(entryArrived(currentCenter: farAway, targetCenter: target, currentPitch: 30))`
    fails for two independent reasons (center far AND pitch tilted) in one assertion, so it
    doesn't by itself prove either gate works in isolation. The other two assertions in the same
    test *do* correctly isolate the center-only and near-boundary cases, so this is a nit, not a
    coverage gap — porting the old test's combined-condition case forward, not a new defect.
  - Owner: `@ios-engineer`, whenever this file is next touched.

- **#4: Branch is based on an older `main`**
  - Where: branch `fix/pin-seed-under-tip` branches from `fb5b2764`; current `main` tip is
    `e98c3d51` (one doc-only commit ahead: the Cruise-voice open-item).
  - What: No code conflict (confirmed via `git diff fb5b2764 92a285a2` vs `git diff --stat
    e98c3d51 92a285a2` — the only extra diff is `docs/open-items.md`, from `main`'s own later
    commit, not from this PR). Purely a rebase-before-merge housekeeping note.
  - Owner: whoever merges.

### 💡 Out of scope (logged, not fixed)

- **#5: `altitudeForSpan`'s FOV approximation is still unverified on a real device**, and is
  still load-bearing for the entry pinch-zoom range, Drive Mode entry altitude, and the
  ambient-look span conversion elsewhere in the app. This PR correctly routes AROUND it for the
  one spot where precision actually mattered (entry *position*); it does not fix the underlying
  "never verified, ~5% is a guess" problem, which remains a tracked risk for every other caller.

## Smoke tests run

- `gh run view 40261968752` — confirmed CI green, 2009/2009, head SHA matches `92a285a2` exactly
  (not a stale/cached run).
- `git diff fb5b2764 92a285a2 --stat` (merge-base, not `main`'s moving tip) — confirmed the diff
  is exactly 3 files / 208 insertions / 46 deletions, matching the commit message's claim; the
  apparent 4th-file (`docs/open-items.md`) diff against `main`'s current tip is from `main`'s own
  later unrelated commit, not this PR.
- Hand-derived `entryCenter` + `entrySpanDegrees`'s combined algebra symbolically (not just
  trusting the new test): `fractionFromTop = (0.5·h - 0.1·h) / h` after substituting
  `topLatitude - seed.latitude`, which reduces to exactly `0.4` for any `h`, `seedLatitude`, or
  screen size, confirming the center-not-span-edges claim in part (b) of the brief.
  Independently re-verified `clampedVisibleWidthMeters`'s and `entrySpanDegrees`' aspect-ratio
  consistency: the span handed to `MKCoordinateRegion` already has the *physical-meters*
  aspect ratio matching `mapView.bounds.size`, so MapKit's own aspect-fit step on `setRegion`
  should be a no-op (nothing to re-widen) — not independently confirmed on a real device/
  simulator render, since no Xcode toolchain exists in this review environment.
  - Traced `onAmbientUserAdjusted` / FT-17a gesture-pause detection
  (`MapViewRepresentable.swift:2990-3116`): both gate on `panGesture`/`pinchGesture` recognizer
  `.state`, not on which MapKit camera API was called, and `onAmbientUserAdjusted` is additionally
  gated on `placementController == nil` — so the entry `setRegion`'s `regionDidChangeAnimated`
  cannot be miscounted as a user-initiated move under either mechanism, confirming part (e) of
  the brief is not a regression.
- Confirmed `AppConstants.curbPinPlacementEnabled = false` and
  `AppConstants.driveModeDefaultEnabled = false` in `Constants.swift` (current HEAD) — both
  features this review cares about are dark today.
- Grepped for other `performNudge`/`settleNudge` callers (`focus(on:)`, `cycleNearbyCurb()`) and
  confirmed via diff that neither was touched.
- Checked the six known Swift compile-failure classes against every changed call site
  (argument order on `entrySpanDegrees`, `clampedVisibleWidthMeters`, `entryArrived`,
  `MKCoordinateRegion`/`MKCoordinateSpan`; `PlacementSpanDegrees`'s memberwise-init order;
  `nonisolated` on the whole `CurbPlacementMapPolicy` enum) — no hits.
- **NOT run:** live simulator build/install/launch/screenshot. No Xcode/`xcrun`/`xcodebuild`
  exists in this Linux review sandbox. This PR does not touch any of the mandatory-live-smoke
  mount-chain files (`MapViewRepresentable.swift`, `ContentView.swift`, `Views/DriveMode*.swift`,
  `.safeAreaInset`), so the hard gate doesn't formally apply — but Findings #1 and #2 are both
  genuinely "needs a real device" items, and this repo's own convention is that the real gate
  for iOS fixes is Kevin's Mac, not an agent review. Flagging explicitly rather than silently
  passing.

## What's working

- The seed-under-tip guarantee is now provably exact, not just "tested exact": I re-derived the
  algebra independently of the new test and it holds for any screen size or latitude, because
  `entryCenter` and `entrySpanDegrees` are forced to share the same `metersPerDegreeLatitude`
  constant. This is the single most important correctness property in the PR and it's solid.
- The dangerous `force==true`/`force==false` asymmetry is structurally eliminated, not
  rebalanced — there is no longer a code path where the two differ in `finishEntry`.
  `settleWithoutNudge()` is now the only exit from entry completion, for both paths.
- `clampedVisibleWidthMeters` deliberately pre-matches the region's physical aspect ratio to the
  view's pixel aspect ratio before handing it to `MKCoordinateRegion`, which is exactly the right
  defense against `setRegion`'s own aspect-fit re-widening the span out from under the tip math.
- Cross-file blast radius is genuinely clean: the PR correctly left `end(restore:)`, the resolve
  loop, and both other `performNudge`/`settleNudge` call sites untouched, and I independently
  confirmed none of PR #138's user-adjust detection or FT-17a's gesture-pause logic can
  misinterpret the entry `setRegion` as a user move.
- Flag-off byte-identical claim holds up against the actual `Constants.swift` values today, not
  just the commit message's assertion.
- The PR is honest about its own gaps — `[COMPILE-UNVERIFIED]` tags are placed exactly where a
  real-device check is actually needed (the ambient-look-pitched-entry transition), not
  decoratively scattered.
- Diff is genuinely minimal and scoped — confirmed against the merge-base, 3 files, no drive-by
  changes.
