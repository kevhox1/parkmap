# Curb-pin "snap to pin is weird" diagnosis, 2026-11-23

Diagnosis only. No code changed, nothing built, no simulator. Evidence is from reading the code at `main` (d8d0ab90) and diffing against build 26 (8788b331). Paths are under `ios/WePark/WePark/`.

**Report (build 26, flags on):** "Snap to pin is still weird. It doesn't actually snap to where I want it to. It just auto locks back on once I let go of the screen."

**Build 26 vs main.** `git diff 8788b331..main` on the curb-pin files (`CurbPlacementMapPolicy`, `CurbPlacementController`, `CurbPlacementSession`, `MapViewRepresentable`, `CurbSnapIndex`) changes only the `tipFraction` plumbing (#37 item 8: 0.40 / 0.36 / 0.30 chosen once at entry from the card config) plus the PR #155 card layout. `CurbSnapIndex.swift` is untouched. Snap, nudge and camera logic are byte-identical in behaviour. On a tall phone the fraction is still 0.40 (`CurbPlacementCard.swift:555`), so nothing since build 26 fixes or changes this report.

## TL;DR (ranked)

1. **The settle nudge teleports the map after release (HIGH, ~70%).** When the finger lifts and the map stops, the controller waits 0.1 s, then moves the camera so the snapped curb point sits under the needle tip (`CurbPlacementController.swift:487-527`, `569-603`). The user dragged the tip to point X. The app decides "the curb is point Y, up to 24 m (about 86 pt at entry zoom) away" and slides the map there. This is by design (spec "settle nudge"), but it is the literal behaviour Kevin describes as "auto locks back on once I let go". The code comment at `:565-568` admits the UIView-wrapped `setCenter(animated: false)` probably does not animate, so in practice it is an instant jump 0.1 s after release.
2. **The snap target is purely "nearest polyline within 24 m", with no way to say "not that one" (HIGH, ~60%, co-cause with 1).** `CurbSnapConfig.acquireRadius = 24`, `releaseRadius = 30` (`Services/CurbSnapIndex.swift:86-87`). A needle over a building lot, a roadway or a median always acquires the nearest curb that exists in the loaded tiles. The jump on release (cause 1) then moves the map to that curb, so every release re-centres on a curb the user may not have meant. Screenshot 2 is exactly this: the needle is over Houston roadway or median, the only Houston curb near it with data is the north side, and the footnote "Nearest curb with data" appears (`CurbPlacementCard.swift:296`, threshold 15 m at `:64`).
3. **The aim point is not the visible head (MEDIUM, ~35%).** The pin is a 44 pt head floating 20 pt above a stem, so the head centre is 64 pt above the sampled tip (`PlacementReticleView.swift:39,41,170`). At 0.28 m/pt that is about 18 m. Users aim with the head; the app samples the tip. Nothing is geometrically wrong (see C), but the visual says "the dot is here" while the sample is 18 m south of it.
4. **Camera re-follow: ruled out.** Nothing in the iOS app ever sets `userTrackingMode`; every follow, recentre and ambient-tighten path is gated off while a session is live (details under A).

Smallest safe fix is a product decision for Kevin and the orchestrator: **drop the automatic settle nudge after a user drag** (keep it only for the explicit chip, locate and VoiceOver paths), and shrink acquire to about 12-15 m with an explicit "no curb here, nearest is X m" state beyond that. See "Recommended fixes".

Nothing here can be fully proven without the device, so the repro below separates cause 1 from cause 2 in one minute.

## Intended behaviour (from the docs)

- `docs/design/curb-pin-placement-design.md` (design review, section 1 "Settle nudge refinements"): after a user pan the map eases so the ghost lands under the needle. Skip threshold 2 pt, dwell 0.1 s, duration 0.14-0.30 s, instant under Reduce Motion (`Services/CurbPlacementMapPolicy.swift:354-378`). The design wanted a "magnet", and the snap rule itself was specified as nearest curb within 24 m with a 2 m dead-band to commit to a side (`CurbSnapIndex.swift:63-117`).
- `docs/qa/curbpin-flip-smoke-2026-11-23.md` verified entry (seed lands on the tip, no jump), card height invariance, exit camera. It did NOT verify pan, release, nudge landing, or the side dead-band: rows M1 (rotate and pitch, AXe failed) and M4 ("2 m side-commit dead-band feel verdict", NOT-SIM-TESTABLE, Kevin device) were never run. The post-release behaviour Kevin reports is exactly the unexercised part. `pr140` P2-2 (ii) also flagged the margin and centring question as "the highest-value Mac check", and no later doc closes it.
- `pr155-curbpin-card-ax-se.md` and `curbpin-se-live-pass-2026-11-23.md` only cover card layout. They do not touch snap behaviour.

## Per-hypothesis verdicts

### A. Camera re-follow after the pan ends: RULED OUT (as a follow-mode; the nudge is a different mechanism)

- `userTrackingMode` is never assigned anywhere in the app. Only comments say "no `userTrackingMode = .follow`" (`ContentView.swift:4615,4624,6665`; `MapViewRepresentable.swift:869,1765`).
- Drive follow (`setDriveCamera` per GPS tick, `ContentView.swift:5277-5288`) is `driveModeActive`-only. The card is not shown and the session is not begun while driving (`ContentView.swift:6223`, entry routing).
- Launch / Find-me recentre: `handleLocationUpdate` defers both pending flags while a session is live (`ContentView.swift:5246-5270`, `CurbPlacementPolicy.recenterPlan`). `recenterMap` has a backstop `if curbPlacement != nil { return }` (`:4793`). `beginCurbPlacement` also clears `recenterOnUserAtLaunch` (`:5812`).
- Ambient look auto-tighten (`applyAmbientDrivingLook` with a re-centre on the fix) is guarded: `handleAmbientLookLocationUpdate` returns when `curbPlacement != nil` (`ContentView.swift:4900`). `onAmbientUserAdjusted` is not fired by placement pans (`MapViewRepresentable.swift:3122-3127`).
- Placement-locate button only moves the camera on an explicit tap (`ContentView.swift:6185-6207`).
- PR #147 `setRegion` happens once, at entry (`CurbPlacementController.swift:248`), not on release.
- `regionDidChangeAnimated` forwards to `handleRegionChanged` (`ContentView.swift:3410-3428`), which loads tiles, rebuilds overlays and refreshes the dot measurement. None of these move the camera.

Residual risk (cannot rule out from code, flag for device): `MapViewRepresentable.updateUIView` was not exhaustively audited for placement. Mount-chain rule says it must not mutate the camera, and nothing in the grep for `setCamera` / `setRegion` outside the CoordinatorActions closures suggests it does.

**But note the near-miss:** the exit camera on Park here / commit centres on the TIP coordinate with the ambient pitch/heading restored (`CurbPlacementController.swift:761-801`, `CurbPlacementMapPolicy.exitCamera`). That is "lock back on" after COMMIT, not after letting go of the screen. Mention only if Kevin says the jump happens on the Park here tap.

### B. Snap target is not what the user intends: CONFIRMED (contributing)

- Search is from the TIP coordinate, not the head or screen centre: `tick()`, `settle()`, `refresh()` all do `mapView.convert(tipPoint, toCoordinateFrom: mapView)` then `index.resolve(pin, ...)` (`CurbPlacementController.swift:289-293, 497-503`).
- Ranking is pure flat-earth distance to polyline edges in a 3x3 cell block of 32 m cells, with an incumbent dead-band (`CurbSnapIndex.swift:393-483`):
  - No incumbent (or incumbent beyond `releaseRadius` = 30 m): nearest blockface within `acquireRadius` = 24 m wins, else `.noCurbInRange`.
  - Incumbent within 30 m is kept unless another blockface is within 24 m AND closer by H (`:440-447`).
- "Curb with data" is not a fallback stage. The index is built only from `tileLoader.segments`, i.e. blockfaces that exist in the loaded tiles (`ContentView.swift:6019-6035`). A no-data curb is not in the index at all, so pointing at it can only resolve to something else. There is no "ranking with fallback"; the footnote is just `distanceMeters > 15 m && !oppositeSideLoaded` on the already-snapped result (`CurbPlacementCard.swift:296`).
- The 24 m radius is large. The doc comment says it "covers nothing inside a building lot, by design" (`CurbSnapIndex.swift:65-68`). On Manhattan blocks the curb is 5-20 m from most of the lot, so a needle on a building (screenshot 1) or on a roadway (screenshot 2) always acquires something. At 0.28 m/pt, 24 m is about 86 pt: nearly a quarter of the screen width.
- Tile data check (`tiles/`, E Houston between 1st and 2nd Ave): only the NORTH side segments carry the cross-street pair "1ST AVENUE | 2ND AVENUE". The south-side segments along that stretch carry different cross streets (ALLEN/ELDRIDGE/ORCHARD/LUDLOW...). So `oppositeSideCandidate` (which requires an identical cross-street pair, `Services/CandidateSegmentSearch.swift:113-120`) finds nothing, `oppositeSideLoaded` is false, and the card prints "Nearest curb with data" even when the south curb exists a few metres further. This is a real data-model gap that makes Houston, and any street whose two sides name different cross streets, look "far" and one-sided. Tile data shape per segment: `id, street, from, to, side, line[[lat,lng]], rules, dominantCategory, oneway, oneway_toward`. Each segment is one side's curb polyline.
- Blue dashed horizontal line in screenshot 1: expected and unrelated. It is the community "YOUR SQUARE" home-zone boundary polygon edge (`MapViewRepresentable.swift:212,2416-2419,2937-2944`: `MKPolygonRenderer`, systemBlue, dash `[7,6]`, 4.5% fill). One edge of the rectangle crossed the screen. It is not hidden during placement (`syncZoneBoundaries` has no placement gate). Not a debug line, not the route, not a coverage boundary. It is visually confusing next to a snap UI. Optional follow-up: hide it while a session is live.

### C. Pin-tip geometry: RULED OUT as a mismatch (but see cause 3 for perception)

- Sample point and drawn tip come from the same function. `CurbPlacementMapPolicy.tipPoint(in:tipFraction:)` (`CurbPlacementMapPolicy.swift:92-94`: x = midX, y = `tipFraction * height`) is used by the controller's sample (`CurbPlacementController.swift:291,497,534,572,638,659,690,768`) and by the reticle's own drawing (`PlacementReticleView.swift` `layoutSubviews`: `tip = tipPoint(in: bounds, tipFraction:)`). The reticle frame equals `mapView.bounds` (`CurbPlacementController.swift:186`), so both are in the same coordinate space.
- The tipFraction is chosen once at entry and passed to both (`ContentView.swift:5884-5892`, `CurbPlacementController.swift:104,171`).
- Rotation and pitch: the sample is `mapView.convert(point, toCoordinateFrom:)`, which is correct for a rotated or pitched map (the A3 pass-1 #1 `estimatedPinCoordinate` bug was fixed through `placementPinCoordinate()`; `ContentView.swift:6140` uses it as fallback). A rotated map (screenshot 1) therefore does not mis-sample. The needle is drawn screen-up regardless of heading, which is fine because only the tip matters. Not verified on device with pitch (flip smoke M1 not run).
- Screenshot 2 "tip/tether offset from the head": expected, not a bug. While a finger is down the needle view is translated up 8 pt (`PlacementReticleView.swift:45, setLifted`), and the tether is drawn from the true (un-lifted) tip on the root layer (`:235`). Also the tether goes from the TIP to the ghost, not from the head, and the head is 64 pt above the tip.
- Margins caveat (UNVERIFIED, could matter for the nudge): the controller sets `layoutMargins.bottom = cardHeight + 8` after entry (`CurbPlacementController.swift:718-739`, applied from `ContentView.swift:5899, 6213-6219`). `convert` is margin-independent, so the sample stays correct. But `performNudge` / `focus` compute `newCenter` assuming `setCenter` puts a coordinate at `bounds` centre (`nudgeTargetScreenPoint`, `CurbPlacementMapPolicy.swift:99`, called at `CurbPlacementController.swift:574-579`). If MapKit centres on the margin-inset rect instead, every nudge lands the ghost about half the card height (roughly 120 pt, 30+ m) off the tip, and the next resolve then picks a different curb or none. Apple's docs are silent; a community thread says centre does not move with margins, but that is unverified. Nobody has measured a nudge landing on device (pr140 P2-2 (ii) is still open). If true it would explain "doesn't snap to where I want", so it is the first thing to test.

### D. Side dead-band stickiness: NOT the cause (minor stickiness exists by design)

- H = `clamp(14 pt * metersPerPoint, 1.5 m, 4 m)` (`CurbSnapIndex.swift:112-116`). At entry zoom (0.28 m/pt) H is about 3.9 m, so a challenger side wins once the tip is about H/2 = 2 m past the street centreline (`:442-444`).
- After a nudge the tip sits exactly on the incumbent curb, so to switch sides the user must drag past the centreline plus 2 m: about 7 pt at entry zoom, less than a finger wobble. Not noticeable.
- `incumbentKey` persists across drags (`CurbPlacementController.swift:347`) and is dropped only on `.noCurbInRange` (`:351`). Incumbent retention up to the 30 m release radius means a tip 25-30 m from the old curb still keeps it unless another curb is within 24 m and closer by H. This is the only real "sticky" path and it only matters at the edge of range.
- It never "keeps the previous block after release" beyond that. `settle()` re-resolves at the final tip with the same incumbent rule.

### E. Release-time re-snap with a different input: NO different input, but the release path is the problem

- The final pass on release (`settle()`, `CurbPlacementController.swift:487-506`) resolves from the TIP, the same input as the live ticks, not from the user's location or the initial candidate. No "reset to initial seed" exists after entry.
- What does run on release, in order: `regionDidChange` returns early if a finger is still down (`:479`), else `settle()`: stop the link, drop the needle (`setLifted(false)`), clear the move flag, resolve, refresh ghost, then **if `userInitiated` and the ghost is >= 2 pt from the tip, schedule the nudge** (`:515-525`, `scheduleNudge` 0.1 s dwell at `:546-563`). This is cause 1.
- Late index swaps can also change the target without any input: tiles load as the user pans (`ContentView.swift:3412` `tileLoader.loadTiles`), `handleSegmentsChanged` calls `rebuildCurbPlacementIndexIfLive`, and when the new index swaps in, `refreshPlacement()` re-resolves at the current pin (`ContentView.swift:6044-6068`, `CurbPlacementController.swift:636-647`). If the user pans toward a not-yet-loaded area and releases, the ghost and card can change a second or so after release with no touch. This is a separate, smaller "it moved by itself" source worth keeping in mind. It does not move the camera.

## Recommended fixes (smallest safe change + tests)

All three are small. Fix 1 alone probably resolves the report.

1. **Stop auto-nudging after a user drag (cause 1).**
   - Change: in `settle()` (`CurbPlacementController.swift:515-525`) delete the `userInitiated` nudge branch. Keep `performNudge` for `focus(on:)` (chip), `cycleNearbyCurb` (VoiceOver) and locate. The ghost, tether and card already tell the user where the pin WILL land, and Park here already saves `snappedCoordinate` (`ContentView.swift:6140-6156`, `CurbPlacementPolicy.parkTarget`), so the camera does not need to move.
   - Alternative if Kevin likes the magnet: cap the nudge (for example only when the ghost is within about 40 pt of the tip, i.e. a true "pull the last few feet") and make it a real animation. A cap leaves long jumps (cause 2) to the user.
   - Tests: `CurbPlacementMapPolicyTests` for the removed or capped `settleNudge` decision. Add a pure `shouldNudgeOnSettle(userInitiated:ghostOffsetPoints:)` so the rule has a unit test (the controller itself needs an MKMapView). Keep existing nudge-duration tests only for the paths that remain. Live: release a drag with a 60 pt ghost offset and confirm the map does not move.

2. **Make the snap say "no" instead of "nearest anything" (cause 2).**
   - Change: reduce `CurbSnapConfig.standard` acquire to about 12-15 m and release to 1.25x of it, and reuse the existing `.noCurbInRange` + "Nearest curb Xm" chip (`ContentView.swift:6080-6125`, probe 100 m) for the rest, so a needle over a building shows a no-curb state with a tappable chip rather than silently choosing a curb 20 m away. Revisit the "> 15 m far curb" copy at the same time (`CurbPlacementCard.swift:64`).
   - Also fix the opposite-side match for streets whose two sides name different cross streets (E Houston case, `CandidateSegmentSearch.oppositeSideCandidate`, `:113-120`): match by geometry (a same-street opposite-side polyline within about 40 m of the foot point) instead of requiring an identical cross-street pair.
   - Tests: `CurbSnapIndexTests` (new acquire/release numbers, a pin 18 m from a curb returns `.noCurbInRange`), `CurbSnapDisplayTests` or `CurbPlacementCardModelTests` (far-curb and opposite-side rows), `CandidateSegmentSearchTests` for the Houston-shaped fixture (north segment "1ST AVENUE | 2ND AVENUE", south segment with different cross streets). This one changes a tuned number the design set (24 m), so it needs the orchestrator's approval, not a silent substitution.

3. **Align what the user aims with and what is sampled (cause 3, optional).**
   - Change: make the ground point the dominant element (larger ground mark, or shrink the 44 pt head), and/or label the tether ("Snaps here"). Alternatively move the head closer to the tip. Pure `PlacementReticleView` constants: `needleHeadDiameter` 44, `needleStemLength` 20, `groundMarkSize` 12x5.
   - Tests: layout constants only; confirm tip and ground mark coordinates are unchanged (`CurbPlacementCardLayoutTests` pattern). Needs Kevin's design call.

4. **Measure the margin question before trusting any nudge (cause C caveat).** A device-only check, no code. If the nudge lands off, either set the margin back to the safe-area value during nudges or compute `newCenter` through `mapView.centerCoordinate`-relative screen maths.

## What can only be confirmed on device, and the exact repro

Kevin, one pass, about a minute. Use a street with curb data on both sides (for example 1st Ave or E 1st St).

1. Long-press the map to start Park placement. Wait for the card.
2. Drag the map slowly so the needle tip sits on the middle of a building lot (not near a curb). Hold. Note the green ghost dot and tether: that is where the app thinks you are pointing.
3. Lift the finger and watch for the next half second. Result A: the map slides or jumps so the ghost dot ends up under the needle tip, and the tether disappears (confirms cause 1). Result B: the map does not move but the card changes street (that is the index swap, cause E). Result C: the map moves but the tether is still there after it settles (confirms the margin/centring suspicion in C).
4. Repeat with the needle tip over the roadway of a wide street (Houston) and over a building 20 m from the curb. If it always picks a curb, note the footnote ("Nearest curb with data"). That is cause 2.
5. Tell us which one you saw. "Map jumps after release" is cause 1. "Pin ends up on a different street or side than I pointed at" is cause 2.
6. Optional: tap Park here and check the saved car pin lands on the green ghost, not the needle tip. The code saves the snapped coordinate, so it should.

Also re-run flip-smoke items M1 (rotated and pitched map) and M4 (2 m side commit) that the simulator could not drive.

## Address-anchoring inventory (not a design)

What exists today that supports "you're parked in front of 123 E 1st St":

- **Reverse geocoding: none.** No `CLGeocoder`, `MKReverseGeocodingRequest`, `MKLocalSearch` or `CLPlacemark` use anywhere in `ios/WePark/WePark`. The only mention is a comment in `Views/PinDetailSheet.swift:283` ("Full reverse-geocode is a TF2 enhancement").
- **Address or building data in tiles: none.** Per-segment keys across `tiles/` are `id, street, from, to, side, line, rules, dominantCategory, oneway, oneway_toward`. No house numbers, no building footprints, no address ranges. A house-number range per blockface would need a `@backend-data` pipeline change (NYC has PAD / LION address-range data), or on-device `MKLocalSearch` / geocoding.
- **Where the parked car stores location:** `Models/ParkedCar.swift:37-83`: `latitude`, `longitude` (the snapped curb foot point when parked through placement, `ContentView.swift:6140-6156`), `detectedSegmentID`, `detectedSide`, `street`, `fromStreet`, `toStreet`, `parkedAt`, `notifyOnRestriction`. Persistence is `NSUbiquitousKeyValueStore` (iCloud KVS) via `Services/ParkPinService.swift`, with UserDefaults used only for legacy migration. Adding an optional `addressText` or `houseNumber` field needs the same Codable-optional treatment as the existing fields.
- **What the snap index knows about frontage:** it knows the blockface (street, side, from/to cross streets) and a `positionFraction` (0-1 along the blockface, from `from` to `to`) via `CurbSnapResult` (`CurbSnapIndex.swift:119-140`, `nearestPointOnPolyline`). It knows nothing about buildings or addresses. With address ranges per blockface (low and high number, parity by side), `positionFraction` interpolates to an approximate house number, which is the natural bridge. `CandidateSegmentSearch.neighborSegment` and `oppositeSideCandidate` exist for walking to adjacent blockfaces.
- **Community pins** already persist `position_fraction` along a segment (`CandidateSegmentSearch.SpotPlacementSnap`, spec §2.2), so "where along the block" is an existing, stored concept for pins even though parked cars store only lat/lng plus segment id.
- **Implication for this report:** once the primary anchor is "the blockface plus a house-number estimate", the 24 m needle snap stops being the whole interaction. The pin position becomes secondary, which weakens the case for investing in nudge and magnet polish now.
