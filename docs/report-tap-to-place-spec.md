# Report flow: tap-to-place + curb-snap-on-display — execution spec

**Open item:** `docs/open-items.md` #22 (Kevin, S14 gate, 2026-09-13).
**Status:** spec-first, not started. **NOT flag-gated** — `AppConstants.communityEnabled = true`
(`Services/Constants.swift:152`), so everything here ships in the flag-off-equivalent binary,
i.e. to 100% of TestFlight users, immediately on merge. Treat this like a core-flow change, not
a Community 2.0 feature-flag rollout.

---

## 0. Open decisions (read first)

Kevin should confirm these four before an engineer starts. Recommendations below; nothing here
is load-bearing on the other three, so partial agreement doesn't block starting on the rest.

| # | Decision | Recommendation |
|---|---|---|
| 1 | Mandatory placement-first vs. optional re-anchor | **Refinement, not a mandatory step.** Ship as an in-sheet "Reposition" affordance the user can ignore entirely. See §1 for the argument against literal placement-first. |
| 2 | Curb-snap timing | **Display-time projection, not write-time.** Retroactively fixes every already-shipped pin with a `segment_id`, no migration, no schema touch. See §2. |
| 3 | Long-press-report interplay | **Gets it for free, no special-casing** — both the resting long-press dialog and the Report pill present the same `ReportSheet`; the affordance lives in the sheet, not the entry point. |
| 4 | In-drive Report button | **Explicitly excluded.** No tap-to-reposition while driving — safety, not an oversight. New `allowsReposition: Bool` param, `false` at that one call site. |

---

## 1. Problem & user story

**Today.** Enforcement/sweeper reports resolve their segment from wherever the user *already
was* when they tapped Report — current GPS (Report pill, in-drive button) or the long-press
point (resting dialog) — then offer a "confirm the street" candidate list of up to 4 nearby
blockfaces (`ReportSheet.confirmStreetSection`, `Views/ReportSheet.swift:975-1056`, fed by
`CandidateSegmentSearch.confirmStreetCandidates`, `Services/CandidateSegmentSearch.swift:86-101`).
That candidate list is *derived from a coordinate the user never chose* — GPS drift, standing on
the wrong curb, or opening the Report pill with no GPS fix yet (map-center fallback,
`ContentView.swift:2294-2312`) all degrade it. If the derived point misses every candidate radius
(35m, `pinDropRadiusMeters`), the report ships with `segmentId: nil` — permanently unattributed
(OD-1).

Kevin's ask (2026-09-13, S14 gate): *"when I report couldn't we also use the pin placement
logic? So that I select where it is then I confirm the street/side?"* He's referring to the
tap-the-curb idiom already shipped for the *other* report tile — "Spot open"
(`Views/SpotPlacementView.swift`, Community 2.0 Phase 2b) already does exactly this: tap the
map, snap to the nearest segment + a position fraction along it, confirm, post. Enforcement and
sweeper reports never got that idiom; they still resolve location passively.

**Why refinement, not mandatory placement-first.** Enforcement/sweeper reports are inherently
time-pressured — the whole point is "the agent/truck is right here, right now, before I forget."
Inserting a mandatory tap-the-map step *before* type selection adds one full screen/interaction
to every single report, for every user, forever (this flow is not flag-gated). The existing
confirm-the-street list already gives a correction path for the common case. Recommendation:
extend that existing step with an optional "Reposition" affordance rather than replacing the
flow's front door. If usage data later shows people reposition on almost every report, that's
the evidence to promote it to a default first step — better to learn that than to guess it.

**Second half of the item — curb-snap-on-display.** Independent of the above, Kevin also flagged
(same gate): *report pins render at the reporter's raw lat/lng, mid-block*, even when the report
carries a confirmed `segmentId`. Confirmed by reading the render path — see §2. This must be
fixed regardless of which placement UX ships, and it benefits pins that already exist in
production today, not just future ones.

---

## 2. Curb-snap-on-display — the bug, and why display-time wins

### 2.1 The bug, cited

`CommunityPinAnnotation.coordinate` (`Views/PinMarkerAnnotation.swift:254-256`):

```swift
var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng)
}
```

This is the literal map-marker position for every community pin type. It always reads the raw
stored `lat`/`lng` — it never consults `pin.segmentId` or `pin.positionFraction`
(`Models/CommunityPin.swift:119`, `:201`) at all. `ReportSheet.performSubmit`
(`Views/ReportSheet.swift:1309-1327`) writes `lat`/`lng` as the literal GPS/tap coordinate and
never passes `positionFraction` to `insertCrowdPin` — confirmed at the call site (no
`positionFraction:` argument) against `CommunityPinService.insertCrowdPin`'s signature
(`Services/CommunityPinService.swift:1557-1567`, `positionFraction: Double? = nil`). So
enforcement/sweeper pins carry a correct `segmentId` but render mid-street, off-curb, wherever
the reporter happened to be standing or driving.

### 2.2 Three inconsistent existing precedents — worth knowing before picking a fix

- **`BlockRestrictionReportSheet`** (the multi-block closure flow) writes `segment.midpoint`
  as `lat`/`lng` at insert time (`Views/BlockRestrictionReportSheet.swift:421`) — a write-time
  snap, but coarse (always the middle of the block, no fraction).
- **`SpotPlacementView`** writes a precise write-time snap: `nearestSegmentSnap` projects the tap
  onto the segment's polyline and returns both `snappedCoordinate` and `positionFraction`
  (`Services/CandidateSegmentSearch.swift:169-193`); `ContentView.submitSpotPlacement`
  (`ContentView.swift:3977-3993`) writes the snapped coordinate, not the raw tap.
- **`ReportSheet`** (enforcement/sweeper) writes the raw, un-snapped coordinate, full stop — the
  bug in this ticket.

Three write paths, three different behaviors. `Models/CommunityPin.swift:196-199`'s doc comment
("nil [positionFraction] = render at the segment midpoint — every existing pin type's current,
unchanged behavior") is *stale* — true for `BlockRestrictionReportSheet` pins, false for
`ReportSheet` pins. That staleness is itself evidence this was never unified at the render layer.

### 2.3 Recommendation: fix it once, at display time

Add a pure projection: given a `CommunityPin` and the currently-loaded `[Segment]`, resolve the
segment by `pin.segmentId`, then:
- if `pin.positionFraction` is present → interpolate along the segment's polyline at that
  fraction (same cumulative-length math `CandidateSegmentSearch.nearestPointOnPolyline` already
  uses internally, `Services/CandidateSegmentSearch.swift:198-226` — that helper is currently
  `private`; promote to `internal` or add a sibling public entry point rather than duplicating
  the math a fourth time, matching this file's own stated "extract the shared helper" mandate);
- else if the segment resolves but there's no fraction → nearest-point projection of the raw
  `lat`/`lng` onto that polyline (same math, `t`-clamped, distance-agnostic — no radius screen,
  we always want *some* point on the known-correct line);
- else (no `segmentId`, or it doesn't resolve against currently-loaded tiles — OD-1 / stale
  boundary) → fall back to raw `lat`/`lng`, unchanged. There is no curb to snap to.

This is a **pure function of (pin, segments) → coordinate**, directly unit-testable, no
`MKMapView` dependency. It fixes:
- Every enforcement/sweeper pin already in production (retroactive, zero migration, zero
  Supabase involvement — Kevin applies no migration for this).
- Every future one, without touching the write path.
- The `BlockRestrictionReportSheet` midpoint pins too (near-no-op there — midpoint is already on
  the line), and any other pin type carrying a `segmentId` — this is a display-layer fix, not
  narrowly an enforcement/sweeper fix.

**Rejected: write-time snap.** Would require touching `insertCrowdPin`'s three call sites,
deciding what "raw tap point" even means once it's discarded, and — critically — does nothing
for pins already in prod. Kevin applies Supabase migrations by hand and none is needed for
display-time; a write-time approach doesn't need a migration either, but display-time strictly
dominates it for this ticket (the title literally says "curb-snap-on-display").

**Performance note.** `CommunityPinAnnotation.coordinate` is a computed property MapKit may read
on every layout pass — do not run the segment lookup/projection inside it. Precompute once at
annotation-construction time, mirroring the existing `bearing` precedent exactly: FT-11 already
resolves a per-pin `bearing` once, in the `toAdd` loop of `syncCommunityPinAnnotations`
(`Views/MapViewRepresentable.swift:1962-1969`, `resolveBearing(for:segmentByID:)`), and stores it
on the annotation (`CommunityPinAnnotation.bearing`, `Views/PinMarkerAnnotation.swift:252`). Add
a parallel `resolveDisplayCoordinate(for:segmentByID:)`, a stored `displayCoordinate` property on
`CommunityPinAnnotation`, and have `coordinate` return it. The `segmentByID` dictionary this
needs already exists in that same loop (`:1960`) — no new O(n) pass.

---

## 3. Tap-to-reposition — architecture

### 3.1 Where it lives

The affordance is a new "Reposition" row inside `ReportSheet.confirmStreetSection`
(`Views/ReportSheet.swift:988-1013`), visible once a report type is selected — **not** gated on
the existing candidate list being non-empty (`showsConfirmStreetStep` requires
`!candidates.isEmpty`, `:1479-1480`; a new, separate gate is needed precisely so this also covers
the OD-1 case — a report that resolved *no* segment at all is the case that benefits most from
being able to place it manually). New static gate, same house style as `showsConfirmStreetStep`:

```swift
static func showsRepositionAffordance(
    communityEnabled: Bool,
    selectedType: ReportType?,
    allowsReposition: Bool
) -> Bool {
    guard communityEnabled, allowsReposition else { return false }
    switch selectedType {
    case .enforcementActive, .sweeper: return true
    case nil: return false
    }
}
```

`allowsReposition: Bool = true` is a new `ReportSheet` init param, additive with a safe default
(matches this file's existing convention for `onRequestStreetClosure`/`onRequestSpotPlacement` —
every new param defaults to "don't offer this path"). The in-drive Report button
(`ContentView.driveActionRow`, `ContentView.swift:2769-2804`) passes `allowsReposition: false`
explicitly, with a comment citing this decision — safety, not an oversight, and *not* reusing
`coordinateSource` (that field's own doc comment at `:128-136` says it's debug-only; repurposing
a documented-debug field as a production gate is the wrong move).

### 3.2 The state-loss landmine — read before wiring `ActiveSheet`

`ActiveSheet.reportPin`'s `Identifiable` id is **keyed off the coordinate**
(`ContentView.swift:335`: `"reportPin-\(coord.latitude)-\(coord.longitude)"`). `.sheet(item:)`
tears down and reconstructs the presented view whenever `id` changes. If a naive implementation
updates the `.reportPin` case's `coord` payload on reposition, SwiftUI will treat it as a *new*
sheet — destroying `ReportSheet`'s `@State` (`selectedType`, `selectedSubTag`,
`selectedHeadingToward`, everything) exactly when the user has invested the most into the form.
**Do not update the `ActiveSheet.reportPin` case's coordinate on reposition.** Push the new
position into the already-presented sheet through a separate channel instead (§3.3). This is the
single most important thing for the implementing engineer to internalize before touching
`ContentView.swift`.

### 3.3 Recommended shape (interface sketch, not production code)

`ReportSheet` gains an overlay-on-top-of-the-original-input state shape, mirroring its own
existing `confirmedSegment` pattern (which already overrides `segment` the same way,
`:206-212`, `:242`):

```swift
struct ReportRepositionUpdate {
    let coordinate: CLLocationCoordinate2D
    let segment: Segment?          // nil if the new tap is itself off-segment
    let candidates: [Segment]      // CandidateSegmentSearch.confirmStreetCandidates(...), or []
}

// New ReportSheet properties:
var repositionUpdate: Binding<ReportRepositionUpdate?> = .constant(nil)   // additive default

@State private var repositionedCoordinate: CLLocationCoordinate2D? = nil
@State private var repositionedCandidates: [Segment]? = nil

private var effectiveCoordinate: CLLocationCoordinate2D { repositionedCoordinate ?? coordinate }
// confirmStreetSection's ForEach reads: repositionedCandidates ?? confirmCandidates
// effectiveSegment (existing) is reassigned the same way confirmStreetRow already does today

.onChange(of: repositionUpdate.wrappedValue) { _, update in
    guard let update else { return }
    repositionedCoordinate = update.coordinate
    repositionedCandidates = update.candidates
    confirmedSegment = update.segment   // existing state var, existing effectiveSegment plumbing
}
```

`performSubmit()` (`:1295-1334`) switches its two `coordinate.latitude`/`coordinate.longitude`
reads (`:1319-1320`) to `effectiveCoordinate.latitude`/`.longitude` — the one line that actually
matters for §2's fix to matter (a repositioned report should write the *repositioned* point, not
the original one — no purpose snapping-on-display a coordinate the user explicitly corrected).

`ContentView` owns the write side of the binding:
- New `@State private var reportRepositionModeActive: Bool = false` and
  `@State private var repositionUpdate: ReportRepositionUpdate? = nil`, same family as
  `blockSelectModeActive`/`spotPlacementActive` (mutually exclusive with both, and with
  `driveModeActive` — reuse the existing exclusivity convention verbatim,
  `ContentView.swift:2181-2185` already composes three of these; add the fourth).
- Tapping "Reposition" in the sheet sets `reportRepositionModeActive = true`. **Does not**
  set `activeSheet = nil`. `ReportSheet` is presented at `.presentationDetents([.medium, .large])`
  (`ContentView.swift:1422`) — at `.medium` the map is already visible and tappable above the
  sheet, the same affordance the FT-20 bottom sheet already trained users on. No sheet-detent
  API needs to be driven programmatically; let the user drag if they need more map (see §6 for
  why not to try to force it).
- `ContentView.handleMapTap(at:)` (`:3769`) gains a `reportRepositionModeActive` branch, ordered
  alongside its existing `spotPlacementActive` branch (`:3776`): reuse
  `findCandidateSegments(lat:lng:radius:max:)` + `CandidateSegmentSearch.confirmStreetCandidates`
  — the exact same two calls every existing report entry point already makes
  (`ContentView.swift:2297-2305`, `:2784-2794`) — build a `ReportRepositionUpdate`, assign it to
  `repositionUpdate`, and drop/move a tentative marker (§3.4).
- Cleanup on sheet dismiss (success or Cancel) resets all three new `@State` vars — fold into the
  existing `.sheet(item: $activeSheet, onDismiss:)` backstop (`ContentView.swift:973`), same shape
  `cancelSpotPlacementMode()` already uses (`:3933-3937`).

### 3.4 Tentative marker

Recommend **reusing `DraftSpotPinAnnotation` as-is** (`Views/MapViewRepresentable.swift:189-193`,
rendered at `:2362-2385`: `mappin.and.ellipse`, `.systemBlue`, `alpha 0.85`, "not yet posted")
rather than adding a near-duplicate class. Semantically it's the same concept — a tentative point
along a blockface, not yet committed — and `spotPlacementActive`/`reportRepositionModeActive` are
mutually exclusive, so there's no collision risk in sharing the type. If the engineer judges a
distinct class clearer for future divergence, that's a fine call to make locally; not worth a
Kevin decision.

---

## 4. Work streams

Both streams touch `Views/MapViewRepresentable.swift` (curb-snap needs the `syncCommunityPinAnnotations`
loop; reposition needs the tentative-marker sync) and `ContentView.swift` — **serialize, don't
parallelize**, per this repo's own standing note ("file contention is the real bottleneck,"
`docs/open-items.md` Notes section). One engineer, one PR, in this order:

1. **@ios-engineer — curb-snap-on-display** (§2). Smallest, most isolated, ships value even if
   §3 slips. `Models`/`Views/PinMarkerAnnotation.swift`/`Services/CandidateSegmentSearch.swift`
   (promote the private helper) + `Views/MapViewRepresentable.swift` (`syncCommunityPinAnnotations`).
   ~0.5 session.
2. **@ios-engineer — tap-to-reposition** (§3). `Views/ReportSheet.swift`, `ContentView.swift`,
   `Views/MapViewRepresentable.swift` (tentative marker sync). Depends on nothing from stream 1
   except sharing a file — no logical dependency, just do it second to avoid two half-finished
   diffs on `MapViewRepresentable.swift` at once. ~1-1.5 sessions (the state-preservation wiring
   in §3.3 is the genuinely fiddly part; the map-tap branch itself is a small, well-precedented
   addition).

No `@backend-data` or `@pwa-maintainer` work — this is 100% client-side rendering + UI, zero
schema change, zero migration for Kevin to apply.

**QA — 1-1.5 passes, elevated rigor.** This ships unflagged to every user of the primary report
surface. QA must explicitly re-verify, not just spot-check:
- The fast path is byte-identical when a user never taps "Reposition" — same candidates, same
  segment, same submitted coordinate as before this change, for all three entry points.
- The in-drive Report button shows no "Reposition" row and behaves identically to today.
- The state-preservation fix in §3.3 actually holds — reposition mid-flow, confirm every
  previously-made selection (type, sub-tag, heading, sweeper direction) survived.
- Curb-snap-on-display against a handful of **real, already-shipped** production pin
  coordinates, not just synthetic test segments — this repo has open, tracked geometry
  data-quality issues (`docs/open-items.md` #26/#26b/#27/#9/#10 — arrow-direction misreads,
  order-dependent polyline generation, duplicate-adjacent-vertices) that could make a
  nearest-point projection land on the *wrong* adjacent segment's polyline in edge cases. Spot
  check, don't assume clean geometry.

---

## 5. Acceptance criteria

**Curb-snap-on-display**
- [ ] AC-1: A `CommunityPin` with a `segmentId` that resolves against currently-loaded segments
  renders its map marker projected onto that segment's polyline, not at raw `lat`/`lng`.
- [ ] AC-2: When `positionFraction` is present, the rendered position uses it (interpolated along
  the polyline), not a fresh nearest-point projection of `lat`/`lng`.
- [ ] AC-3: When `segmentId` is nil, or doesn't resolve against the currently-loaded tile set,
  the marker renders at raw `lat`/`lng` — unchanged (OD-1 / stale-boundary fallback).
- [ ] AC-4: No change to any other consumer of `pin.lat`/`pin.lng` (zone resolution, crew-feed
  distance sort/near-me filtering, callout "near X" labels) — this is a marker-position-only
  change, scoped to `CommunityPinAnnotation.coordinate`.
- [ ] AC-5: No new Supabase migration, no schema change, no write-path change.
- [ ] AC-6: Pure projection function is unit-tested against a known polyline + known off-line
  point, independent of `MKMapView`.

**Tap-to-reposition**
- [ ] AC-7: With `communityEnabled == true` and `allowsReposition == true`, selecting
  Enforcement or Sweeper shows a "Reposition" affordance, including when no segment resolved at
  entry (`confirmCandidates` empty / OD-1).
- [ ] AC-8: The in-drive Report button (`driveActionRow`) never shows the affordance
  (`allowsReposition: false` at that call site) — no map-tap capture while driving.
- [ ] AC-9: Tapping the map while reposition mode is active re-runs the same
  `findCandidateSegments` + `confirmStreetCandidates` search every existing entry point already
  uses (same 35m radius), and updates the sheet's confirm-the-street list in place — the sheet is
  never dismissed/re-presented, and no previously-made selection (`selectedType`, `selectedSubTag`,
  `sweeperDirection`, `selectedHeadingToward`, `headingNotSure`) is lost.
- [ ] AC-10: Submitting after a reposition writes the *repositioned* coordinate (and, via AC-1,
  the eventual marker renders correctly on it) — not the original entry coordinate.
- [ ] AC-11: A tap in reposition mode that lands beyond the search radius does not crash and
  does not silently adopt a wrong segment — matches the existing "off-segment" degrade-gracefully
  behavior (empty candidates, `segment: nil`).
- [ ] AC-12: A tentative marker appears at the reposition tap point and moves (does not
  duplicate) on a second tap, mirroring `SpotPlacementView`'s "tap elsewhere to move it" idiom.
- [ ] AC-13: Fast path (no reposition tap ever made) is behaviorally and visibly unchanged from
  pre-this-spec `ReportSheet` for all three entry points.
- [ ] AC-14: No "avoid," "ticket," "fine," "evasion," or "dodge" language in any new copy
  (matches AC-R17 precedent already enforced elsewhere in this file).
- [ ] AC-15: The "Reposition" row/button meets this codebase's established generous-touch-target
  convention — >=44pt minimum height, consistent with `driveActionRow`'s own documented 48pt-min
  precedent (`ContentView.swift:2763`) and `confirmStreetRow`'s existing row padding
  (`Views/ReportSheet.swift:1041-1042`).

---

## 6. Out-of-scope follow-ups (noticed, explicitly punted)

- **Promoting tap-to-place to a mandatory first step.** Deferred per §1's reasoning — revisit
  only with usage evidence that people reposition on most reports.
- **Write-time `position_fraction` for enforcement/sweeper pins.** Not needed for this fix
  (display-time alone resolves the visible bug); would only matter if within-block incident
  position becomes analytically interesting later. New backend follow-up if ever wanted.
- **Backfilling `position_fraction` on existing rows.** Unnecessary — display-time projection
  fixes rendering without touching stored rows.
- **Programmatically collapsing the sheet to `.medium` when reposition mode starts.** This
  codebase has no existing usage of `.presentationDetents(_:selection:)` (checked — every current
  call site is the bare, non-driven form). Forcing one in for this feature is new-pattern risk for
  a "nice to have." If smoke reveals users can't find/reach the map at `.large`, that's a fast
  follow (a hint label pointing at the drag handle is the cheap first try), not a blocker here.
- **Extending reposition to `BlockRestrictionReportSheet`'s multi-block closure flow.** Different
  interaction model (multi-block select, not single-point placement) — separate flow, separate
  future spec if wanted.
- **Fixing the stale `Models/CommunityPin.swift:196-199` doc comment's blanket claim.** Small,
  free cleanup — worth a one-line comment fix in the same PR since the engineer will be reading
  that exact file, not worth its own session.
