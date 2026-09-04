# Community 2.0 S13a QA Pass 1 — 2026-09-04

**Reviewed:** branch `ios/community-s13a` at `e755661f` (base `cc55145e`, doc-count fix `e755661f`), against
`docs/design/community-2.0-hero-gap-inventory.md` WP1+WP2, `docs/community-2.0-roadmap.md` S13a row,
locked decision #6, `design/screenshots/01-03`, `design/prototype.html:55-83,746-747,1020-1035`.
**Verdict: MERGE-AFTER-MAC-GATE.**

## Summary

This is a careful, well-scoped PR. The single highest-risk requirement — zero changes to the existing
curb-polyline rendering pipeline in `MapViewRepresentable.swift` — is genuinely true (diff-verified: the
entire file diff is additive, zero `-` lines outside the diff header). The I-1 no-camera-mutation
invariant is preserved in `syncZoneBoundaries`. Overlay/annotation sync is correctly idempotent (guarded
adds, cheap-equality-gated label rebuilds). The CURB COLORS legend is byte-verbatim against the
prototype's `legend` array, and the LIVE PINS legend was independently verified against
`PinMarkerAnnotation.markerStyle(for:)`/`ringMarkerImage(for:)` — the "shipped marker treatment" claim is
true, not asserted lazily. The 4-vs-6-row legend deviation is real and justified: `.construction`/`.blockNote`
are confirmed absent from `ContentView.mapMarkerTypes(communityEnabled:)`'s allow-list (which resolves to
`AppConstants.communityPhase1PinTypes` → only `[.openSpot, .leavingSoon]`), so those two pin types never
reach the map as markers today. The double-POST fix is correctly scoped to the service layer, cannot
permanently wedge (the guard clears unconditionally after the non-throwing `upsertToken` awaits, success
or failure), and ships with a test that actually reproduces the same-turn race the prior test couldn't
catch. Static test count matches the PR's claim exactly: 1183 (main) → 1208 (branch), +25.

The one real judgment call worth Kevin's explicit attention (not a code defect) is the "YOUR SQUARE"
home-zone label: when the user has no parked car, it labels whatever zone the *viewport* happens to be
centered on, which can read as a false claim of "this is your home turf" while browsing a zone that isn't.
The PR flags this itself and the reasoning is defensible given the app has no other home-zone concept —
this is Kevin's call, not a QA blocker.

## Acceptance criteria checklist

- [x] Report pill (bottom-left) + "?" button (bottom-right) float above the sheet peek — verified via
      `communityMapChromeOverlay`'s `VStack + Spacer()`, `browseSheetPeekHeight + 12` padding, same
      convention as `spotPlacementConfirmOverlay`/`confirmPromptOverlay`/`parkingGuideBannerOverlay`
- [x] Report pill tap → `ActiveSheet.reportPin`, current-GPS-with-map-center-fallback, documented
      `coordinateSource` — verified in `handleReportPillTap()`, matches the `ActiveSheet.reportPin`
      case's argument order exactly
- [x] Long-press dialog unchanged — confirmed zero diff to the long-press handler / `.confirmationDialog`
      call sites
- [x] "?" button → `MapKeyLegendView` via `.medium`-detent sheet through `ActiveSheet.mapKeyLegend` —
      verified, follows the established single-sheet-rule dismiss-to-`.browseNav` catch-all with no
      special-case wiring needed
- [x] CURB COLORS legend copy verbatim — verified character-for-character against
      `design/prototype.html:1020-1026` (all 5 rows)
- [x] LIVE PINS legend describes the shipped marker treatment, not the prototype's orange rings —
      verified against `PinMarkerAnnotation.markerStyle(for:)`/`ringMarkerImage(for:)` source, exact
      symbol/color match
- [x] Dashed zone-boundary overlay for all three seeded zones — verified `communityZoneIds` = 
      `["nolita","soho","les"]`, `CommunityZoneBounds.box(for:)` values match the applied migration
      seed comment, `zoneBoundaryCoordinates` produces a correctly-ordered closed rectangle ring
- [x] "YOUR SQUARE · {ZONE}" label for the home zone — present, correct priority (parked car > fallback)
      — see Findings for the fallback-semantics judgment call
- [x] `MapViewRepresentable`'s curb-polyline rendering + I-1 untouched — diff-verified, zero deletions
- [x] Foreground double-POST fixed and tested — verified logic + a genuine race-reproducing test
- [x] All new chrome flag-gated, flag-off byte-identical — verified: `showZoneBoundaries`,
      `homeZoneId`-source, and `communityMapChromeVisible` all trace back to `AppConstants.communityEnabled`
      (currently `false`, unchanged by this PR)
- [ ] **Not verified — requires Mac.** Live rendering: this repo's own PR-class rule (any PR touching
      `MapViewRepresentable.swift`/`ContentView.swift`) requires a live-UI smoke before merge sign-off;
      I have no Xcode toolchain in this environment. See Kevin's gate checklist below.

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: "YOUR SQUARE" label can label a zone that isn't actually the user's home**
  - Where: `ContentView.communityHomeZoneId` / `resolveHomeZoneId(parkedCarLat:parkedCarLng:viewportCenterLat:viewportCenterLng:)`
  - What: With no parked car, the home-zone label falls back to whatever zone the **map viewport**
    is currently centered on. Since all three zone boxes always render (`showZoneBoundaries` is gated
    only on the flag, not on mode), panning from Nolita into SoHo with no car parked flips the label
    from "YOUR SQUARE · NOLITA" to "YOUR SQUARE · SOHO" — a zone the user may have zero relationship
    to, browsed for the first time thirty seconds ago.
  - Expected (per prototype intent, screenshot 03): "YOUR SQUARE" reads as a fixed, home-anchored
    concept — the dashed box in the prototype never moves as the (fixed) camera pans, because the
    prototype has no pan interaction in this screen at all. This app's live, pannable map makes the
    label's semantics genuinely different, and the PR's own doc comment concedes this is "a judgment
    call, not silently decided."
  - Repro: flag on, no parked car, pan the map from a point inside the Nolita box to a point inside
    the SoHo box; the label text should visibly change zone name.
  - Owner: `@ios-engineer` if Kevin rules to change the fallback; otherwise this is a **ruling**, not
    a fix — recommend Kevin decide between (a) ship as-is (defensible: no other home-zone concept
    exists in the app today), (b) suppress the label entirely when there's no parked car (safer,
    loses some of the screenshot-03 glanceability), or (c) invest in a real "home zone" preference in
    a later session. Not blocking S13a's merge either way.

### 🟢 Minor / nit

- **#2: Zone-label add/remove churn when panning back and forth across a box boundary with no parked
  car.** `syncZoneBoundaries`'s `lastAppliedHomeZoneId` gate correctly avoids rebuilding on every
  `updateUIView` tick, but a user oscillating near a zone boundary (e.g. dragging along Houston St
  between Nolita and outside-all-zones) will still fire `removeAnnotation`/`addAnnotation` on every
  crossing. Cheap, not a leak, just worth knowing about if a future drive-test flags jank near a zone
  edge.
- **#3: Zone-boundary overlay + label are NOT mode-hidden the way the Report pill/"?" button are.**
  `showZoneBoundaries: AppConstants.communityEnabled` has no `!driveModeActive` guard, unlike
  `communityMapChromeVisible`. Likely fine (passive, non-interactive map decor, confirmed it can't
  intercept touches — see Focus Area 1 below), but it means the dashed box + label will be visible and
  can flicker/relabel during Drive Mode's heading-up camera. Worth an explicit eyeball during the live
  smoke (see gate checklist) rather than assuming it's inert.
- **#4: Docs not updated in this PR** — `docs/open-items.md` #13 (double-POST) and #12 item ①
  (long-press discoverability, resolved by the Report pill) aren't marked closed, and the roadmap's
  S13a row isn't checked off. Consistent with this repo's established pattern (doc updates land in a
  separate commit after merge, e.g. `58d9a268` after PR #101) — not a defect, just flagging so the
  post-merge doc pass doesn't get skipped.

### 💡 Out of scope (logged, not fixed)

- `docs/open-items.md` #12 items ②–⑥ (sweeper affordance, taxonomy copy, confirm-street fold,
  0%-accuracy copy, HEADING TOWARD sweeper wiring) are correctly NOT touched by this PR — none of them
  are S13a-scoped per the open-items table (S13/S13b/S13c), and this PR doesn't claim to address them.
  No scope-creep demanded.

## Focus-area verification detail

**1. MapViewRepresentable safety (highest stakes).**
- Curb-polyline pipeline: `git diff` on this file shows **zero removed lines** outside the diff
  header — confirmed by `git diff origin/main...origin/ios/community-s13a -- .../MapViewRepresentable.swift | grep '^-' | grep -v '^---'` returning empty. Purely additive.
- I-1: `syncZoneBoundaries` only calls `addOverlay`/`removeOverlay`/`addAnnotation`/`removeAnnotation`
  — no `setRegion`/`setCamera`/`region =` anywhere in the new code. Verified by reading the full method
  body.
- Idempotency: `zoneBoundaryOverlays.isEmpty` gates the one-time polygon build (never rebuilt after);
  `lastAppliedHomeZoneId != homeZoneId` gates the label rebuild. Flag-off → flag-on → flag-off cycles
  correctly reset both to empty/nil, so no dangling references or duplicate overlays across repeated
  `updateUIView` calls. Confirmed no leak path.
- Z-order/hit-testing: this codebase's tap handling is a custom `UITapGestureRecognizer` doing manual
  point-to-annotation and point-to-segment distance math (`handleTap(_:)`), NOT MapKit's overlay hit-
  testing — `MKOverlayRenderer`/`MKPolygonRenderer` objects are never touch-interactive in MapKit
  regardless of z-order. The new `ZoneBoundaryPolygon` renderer cannot intercept a curb-line tap by
  construction. Annotation views (pins) always composite above overlay renderers in MapKit's rendering
  model regardless of add order, so "zone overlays render under pins" is architecturally guaranteed,
  not just a styling choice — verified this holds for the new `ZoneLabelAnnotationView` too (it's an
  annotation view, so it also renders above the polygon overlay layer, which is correct: the label
  should be legible over its own box).
- Class-subclassing pattern (`ZoneBoundaryPolygon: MKPolygon`, `ZoneLabelAnnotation: MKPointAnnotation`)
  exactly mirrors this file's own proven precedents (`SelectedPolyline: MKPolyline { var currentState }`,
  `CarPinAnnotation`/`DraftSpotPinAnnotation` etc.) — high confidence this compiles.
- New files (`MapKeyLegendView.swift`, `CommunityS13aTests.swift`) have no corresponding `.pbxproj`
  diff — checked whether that's a real gap: the project uses Xcode 16+
  `PBXFileSystemSynchronizedRootGroup` (confirmed via `grep` on `project.pbxproj`), so new files under
  a synchronized folder are automatically included in the target with no explicit membership entry
  needed. Not a defect.

**2. Flag-off parity.** `communityMapChromeVisible(communityEnabled:driveModeActive:blockSelectModeActive:spotPlacementActive:)`
is a pure `nonisolated static` function, wired at the real call site (`communityMapChromeOverlay`'s
`@ViewBuilder if`), reading the real `AppConstants.communityEnabled` (still `false`, unchanged by this
PR). `showZoneBoundaries`/`homeZoneId` at the `mapRepresentable` call site both trace to the same flag.
No second, un-gated path found.

**3. Report pill routing.** Reuses `ActiveSheet.reportPin` with matching argument order/names. GPS-vs-
map-center fallback is honestly labeled (`"current GPS (map chrome)"` / `"map center (map chrome, no GPS
fix)"`) per the existing `coordinateSource` diagnostic convention. Collision check: `driveActionRow`
(Drive Mode's own Report button) is gated `if driveModeActive` inside `bottomSafeAreaContent`;
`communityMapChromeOverlay` requires `!driveModeActive`. These are mutually exclusive by construction —
confirmed both can never render simultaneously.

**4. Map key.** CURB COLORS: all 5 rows verified verbatim, character-for-character, against
`design/prototype.html:1020-1026`. LIVE PINS: all 4 rows' SF Symbol names/colors verified against
`PinMarkerAnnotation.markerStyle(for:)` (teal `person.badge.clock.fill`, cyan `truck.box.fill`) and
`ringMarkerImage(for:)` (`systemBlue` ring, "P"/🚙 glyphs) — exact match, not a paraphrase. 4-vs-6 row
deviation verified against the actual marker allow-list (`ContentView.mapMarkerTypes` →
`AppConstants.communityPhase1PinTypes` → `[.openSpot, .leavingSoon]` only) — `.construction`/`.blockNote`
are genuinely never map markers today, so dropping their legend rows is correct, not a shortcut.

**5. Zone geometry.** `CommunityZoneBounds` box values match the file's own comment ("verbatim from the
applied seed rows"); `zoneBoundaryCoordinates` builds a correctly-ordered NW→NE→SE→SW ring (`MKPolygon`
auto-closes). `zoneDisplayName` matches "NOLITA"/"SOHO"/"LES" literals. Home-zone derivation: "parked car
beats X" priority genuinely mirrors `updatePushZoneFromParkedCarOrLocation`'s own priority order (verified
by reading that function); the second-tier fallback intentionally diverges (viewport vs. GPS) as
documented — see Finding #1 for the judgment-call assessment.

**6. Double-POST fix.** `inFlightCandidate` set synchronously before the `Task` is created, cleared
unconditionally after `await upsertToken(candidate)` regardless of success/failure (that function is
non-throwing; internal errors are swallowed via `guard`/`try?`, not propagated) — no permanent-wedge path
found. The new test (`testAttemptUpsert_backToBackCallsBeforeFirstCompletes_onlyOneNetworkRequest`)
deliberately omits the `await` between calls, genuinely reproducing the same-turn race the prior test
(`sameCandidateTwice`, which awaits in between) could not catch. Confirmed this is a real dedupe
assertion, not a rename of the existing test.

**7. Tests.** 24 tests in `CommunityS13aTests.swift` (header count now correct post `e755661f`), +1 in
`PushRegistrationServiceTests.swift` = 25. Independently static-counted the whole suite on both branch
tips: `origin/main` → 1183, `origin/ios/community-s13a` → 1208. Matches the PR's claimed math exactly.
Geometry tests assert actual coordinate values (not just non-nil) — `testZoneBoundaryCoordinates_fourCornersInBoxOrder`
checks all 4 corner lat/lngs against the box, `testZoneLabelCoordinate_insetFromTopLeftCorner_staysInsideBox`
checks strict inequalities on both axes. Gating tests cover both flag states × all three mode exclusions.
Curb-color pinning test asserts the actual description strings, not just row count.

**8. Copy/palette audit.** `MapKeyCurbColorEntry.color` reuses `ParkingColors` constants (no new hex
literals) — confirmed `ParkingColors.restricted`/`.restrictionComingSoon`/`.meteredActive`/
`.freeComfortably`/`.unknown` all exist as `Color`, matching the entry struct's `Color` type. Footer copy
correctly does not claim a pulse/fade animation the app doesn't have (verified by reading
`visiblePins`'/TTL removal semantics referenced in the file header — pins are removed outright, not
faded).

## Smoke tests run

- Static diff review of all 6 changed files (`ContentView.swift`, `MapViewRepresentable.swift`,
  `MapKeyLegendView.swift`, `PushRegistrationService.swift`, `CommunityS13aTests.swift`,
  `PushRegistrationServiceTests.swift`) — full read, not just the PR description.
- `git diff ... -- MapViewRepresentable.swift | grep '^-'` — confirmed zero non-header deletions.
- Independent static test count on both `origin/main` and `origin/ios/community-s13a` tips (cloned to a
  scratch checkout, not relying on the PR's own arithmetic): 1183 → 1208, +25, matches claim.
- Cross-referenced `MapKeyLegendView.curbColorEntries`/`livePinEntries` against
  `design/prototype.html:1020-1035` line-by-line and against `PinMarkerAnnotation.swift`'s
  `markerStyle(for:)`/`ringMarkerImage(for:)` source.
- Cross-referenced `CommunityZoneBounds.swift`'s box values and `ContentView.mapMarkerTypes`/
  `AppConstants.communityPhase1PinTypes` against the PR's claims about `.construction`/`.blockNote`.
- Read `design/screenshots/01-home-collapsed.png`, `02-map-key.png`, `03-your-square.png` directly (image
  read) and compared button placement/legend content/label text against the diff's intent.
- Confirmed `AppConstants.communityEnabled` is still `false` on this branch (flag not flipped).
- Confirmed the project uses `PBXFileSystemSynchronizedRootGroup` — new files don't need explicit
  `.pbxproj` membership on this project.
- **Not run — no Mac available in this environment:** `xcodebuild build`/`test`, simulator install/launch,
  live screenshot inspection. This is the mandatory remaining gate — see checklist below.

## What's working

- The additive-only discipline on `MapViewRepresentable.swift` is exactly right for a file this risky —
  every new symbol is genuinely new, nothing existing was touched, and the diff is trivially auditable
  because of it.
- The LIVE PINS legend is the strongest single piece of this PR: rather than trusting the standing
  exception by assertion, the code actually reuses/mirrors the shipped marker constants, so the legend
  cannot silently drift from what the map draws.
- The double-POST test is a genuinely good regression test — it reproduces the exact race by
  withholding the `await`, not just re-asserting the already-fixed synchronous-dedupe case.
- Every judgment call (home-zone fallback, pill styling vs. paint-order stroke, 4-vs-6 legend rows) is
  flagged explicitly in both the PR body and in-code doc comments, with reasoning, rather than silently
  decided — this made the QA pass meaningfully faster and more confident.

## Kevin's gate checklist (Mac)

**Standard mount-chain smoke (required for any `MapViewRepresentable.swift`/`ContentView.swift` PR):**
1. `xcodebuild build` + `test` on the branch — confirm 1208/1208 (flag off, default).
2. Install + launch on sim, flag OFF (default): confirm toolbar buttons (locate/find-car/Park Until),
   ASP banner, curb polylines all render exactly as before — **no Report pill, no "?" button, no dashed
   zone box anywhere.** This is the flag-off byte-identical check; screenshot it.
3. Flip `AppConstants.communityEnabled = true` locally, rebuild, relaunch.

**S13a-specific checks (flag ON):**
4. Screenshot the home/browse view at a zoom similar to `design/screenshots/01-home-collapsed.png`:
   confirm the Report pill (bottom-left, orange flag + "Report" text) and "?" button (bottom-right,
   circular) both float above the sheet's peek, not clipped by it.
5. Tap "?" — confirm `MapKeyLegendView` presents at `.medium` detent; screenshot and compare row-by-row
   against `design/screenshots/02-map-key.png`: 5 CURB COLORS rows (Red/Orange/Amber/Green/Gray with the
   verbatim descriptions above), 4 LIVE PINS rows (not 6 — confirm no closure/block-note row), footer
   text present and not claiming a pulse animation.
6. Dismiss the legend, tap the Report pill — confirm it opens the report flow at current GPS (check the
   `#if DEBUG` `coordinateSource` diagnostic reads `"current GPS (map chrome)"` with a live fix, or
   `"map center (map chrome, no GPS fix)"` in the simulator before a location is set).
7. Long-press the map — confirm the existing `.confirmationDialog` "Report enforcement or sweeper" still
   works unchanged, side-by-side with the new pill's own entry point.
8. Zoom/pan to a view showing the Nolita/SoHo boundary similar to `design/screenshots/03-your-square.png`:
   confirm the dashed blue zone boundary box(es) render, with the subtle fill, UNDER the live pin markers
   (drop a test pin inside a zone if any exist, confirm it's visually on top of the dashed box, not
   hidden behind it).
9. With no parked car, pan the map from inside the Nolita box to inside the SoHo box: confirm the "YOUR
   SQUARE · {ZONE}" label follows the viewport (per Finding #1) — this is EXPECTED behavior per this
   implementation, not a bug; the point of this check is to give Kevin a live look at whether that
   behavior reads as intended or should be revisited.
10. Enter Drive Mode: confirm the Report pill/"?" button both disappear (replaced by `driveActionRow`'s
    own Report button) and confirm whether the dashed zone box/label remain visible in the background —
    per Finding #3, they're not mode-gated, so this should show them still present; eyeball whether that
    reads as clutter against the heading-up rotated camera.
11. Enter block-select mode and spot-placement mode separately: confirm Report pill/"?" button hidden in
    both.
12. Foreground the app from background (or simulate app-state transition) with a zone set: confirm via
    logs/breakpoint (or just trust the passing unit test) that only one `device_push_tokens` POST fires,
    not two — this one is hard to visually smoke-test without network inspection, the unit test is the
    primary evidence here; Charles Proxy / Xcode network debugger on-device would be the strongest
    additional check if time allows.

**What to screenshot for the record:** flag-off parity (step 2), pill+button placement (step 4), legend
content (step 5), zone boundary at the Nolita/SoHo seam (step 8), Drive-Mode-with-zone-box-still-visible
(step 10).
