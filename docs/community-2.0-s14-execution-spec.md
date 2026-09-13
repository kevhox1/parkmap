# Community 2.0 — S14 Execution Spec: Manhattan Zone Rollout

**Status: READY TO BUILD.** Roadmap: `docs/community-2.0-roadmap.md` S14 row. Data proposal (RULED
by Kevin 2026-09-08, "41 zone ruling is good for now"): `docs/community-2.0-manhattan-zones.md` +
`supabase/06-manhattan-zones.sql` (DRAFT — Kevin applies by hand, see the ceremony at the end of this
doc). This spec covers the **client session only** — no further SQL changes, no re-litigating the
zone list, boundary choices, or the id-stability decision. All of that is locked.

**Codebase touched: iOS only.** No PWA work (the PWA has no crew-feed/zones surface). No new
Supabase migration beyond the already-drafted-and-approved 06. `AppConstants.communityEnabled`
stays `false` throughout — this ships dark, same as every Community 2.0 session since S1.

---

## Read this first — open decisions

1. **Picker UI: build now from this spec's default, or route through `@designer` first?**
   `docs/community-2.0-manhattan-zones.md` recommended a `@designer` hand-off before this session.
   This spec instead specifies a buildable default (§3 below) so the session isn't blocked.
   **Recommend: build now, designer pass later if warranted** — the flag stays off, so a mediocre
   first cut costs nothing external and is fully revisable before any user sees it. Say the word if
   you'd rather gate on a design review first.
2. **Chip-row visible count (8 nearest + "More") and "flat nearest-first + search" for the overflow
   sheet, not the doc's grouped-by-area suggestion.** Purely cosmetic, freely tunable, doesn't touch
   data or schema. Flagging so you know grouping was consciously deferred, not missed — see
   "Out-of-scope follow-ups."
3. **Not really your call, just flagging for awareness:** the zone fetch this session adds runs for
   **every** user, flag on or off — see the callout in Architecture §1 for why that's required, not
   optional.

Everything else below implements decisions already locked in the roadmap and the ruled proposal doc.

---

## 1. Problem & user story

Today the app's "zone" concept — the crew feed's 3 chips, the zone-boundary map overlay, and the
`zone_id` stamped on every crowd-reported pin — is backed by a **compiled-in Swift table**
(`ios/WePark/WePark/Services/CommunityZoneBounds.swift`) hardcoding exactly three boxes
(nolita/soho/les). Kevin ruled 2026-09-08 that Manhattan needs ~41 zones for meaningful coverage,
and the data side of that (`supabase/06-manhattan-zones.sql`) is written and approved. **This session
makes the client stop hardcoding zones and fetch them from the now-larger `zones` table instead** —
so that when Kevin applies migration 06, the app picks up all 41 zones with **zero further app
changes or deploys.**

User-facing story, once the flag eventually flips: instead of only ever seeing "Nolita / SoHo / LES,"
a user anywhere in Manhattan sees the neighborhood squares actually nearest them, nearest-first, with
their own parked-car (or current-location) square pinned as home — "closest squares to you," per
Kevin's own framing (2026-09-13), not an alphabetical wall of 41 names.

## 2. Scope — In / Out

**In:**
- `Models/Zone.swift` — new `Zone` model matching the `public.zones` row shape.
- `Services/ZoneStore.swift` — new service: fetch-at-launch, on-disk cache fallback, the
  point-in-zone / zone-by-id pure geometry helpers (`ZoneGeometry`), and the nearest-first ordering
  helper (`ZoneOrdering`). Replaces and retires `Services/CommunityZoneBounds.swift`.
- Migrating every existing `CommunityZoneBounds` consumer (9 call sites across 5 files — full list in
  §2 of Architecture) to read from the fetched `[Zone]` list instead of the compiled table.
- Replacing `CrewFeedSection`'s fixed 3-case `CommunityZone` enum and `zoneChipsRow` with a
  data-driven, scalable picker (nearest-first chip row + search/overflow sheet).
- Unrecognized/retired `zone_id` fallback behavior (a pin/message whose stored id isn't in the
  current fetched list degrades to the same lat/lng reverse-lookup nil already uses).
- Full test coverage: pure-logic + wire-shape, per §5.
- QA pass(es) + Kevin's Mac gate, sequenced with the migration ceremony (§6).

**Out (explicitly deferred, not this session):**
- Anything in `supabase/06-manhattan-zones.sql` itself — it's written, ruled, and untouched here.
- True polygon/point-in-polygon geometry (the documented post-v1 upgrade path, OQ-1). Bounding boxes
  stay the representation.
- Flipping `AppConstants.communityEnabled`. Unrelated gate (the build-18/20 drive test), unaffected
  by this session.
- Grouped-by-area zone browsing (Downtown/Village/Midtown/etc.) — the overflow sheet ships flat
  nearest-first + search instead (§3). Noted as a deferred designer-facing enhancement.
- PWA — no community/zones surface exists there; not touched.
- The stale "three NYC neighborhoods today" comment in `supabase/functions/send-community-push/index.ts:98`
  — cosmetic, zone-count-agnostic logic (verified: the 500-token cap is per-zone token volume, not
  zone count), not worth a function redeploy on its own.

## 3. Architecture

### 3.1 Fetch-at-launch design

**New model — `Models/Zone.swift`:**

```swift
struct Zone: Identifiable, Equatable, Hashable, Codable {
    let id: String
    let name: String
    let latMin: Double
    let latMax: Double
    let lngMin: Double
    let lngMax: Double

    private enum CodingKeys: String, CodingKey {
        case id, name
        case latMin = "lat_min", latMax = "lat_max"
        case lngMin = "lng_min", lngMax = "lng_max"
    }

    var areaApprox: Double { (latMax - latMin) * (lngMax - lngMin) }
    func contains(lat: Double, lng: Double) -> Bool {
        lat >= latMin && lat <= latMax && lng >= lngMin && lng <= lngMax
    }
}
```

**New service — `Services/ZoneStore.swift`** (mirrors `ZoneMessageService`'s house shape exactly —
`@MainActor @Observable`, raw `URLSession` + `Codable`, no supabase-swift PostgREST client, manual
`CodingKeys`, no `Authorization` header since `zones_select_all` is `using (true)`, same AC-D21
precedent every other read path here already relies on):

```swift
@MainActor
@Observable
final class ZoneStore {
    private(set) var zones: [Zone] = []
    private(set) var isLoading = false
    private(set) var fetchError: Error? = nil

    private static let cacheKey = "wepark_zones_cache_v1"

    // Called once from ContentView.performLaunchSetup(). Seeds `zones` synchronously from the
    // on-disk cache (if any) BEFORE the network attempt resolves, so a picker mounted mid-fetch
    // never renders emptier than the last successful launch.
    func loadZonesIfNeeded() async {
        zones = Self.loadCache() ?? []
        await fetchZones()
    }

    func fetchZones() async {
        // GET rest/v1/zones?select=id,name,lat_min,lat_max,lng_min,lng_max&order=id&id=not.eq.soho-les
        // On success: replace `zones` wholesale, persist to cache, clear fetchError.
        // On failure (non-2xx / network / decode error): set fetchError, leave `zones` at
        // whatever loadZonesIfNeeded() seeded (cache or empty) — same fail-soft posture as
        // ZoneMessageService.fetchMessages.
        // Belt-and-braces: filter out "soho-les" BOTH via the query param above AND client-side
        // after decode (mirrors CrewFeedMerge.merge's precedent of re-filtering data that's
        // already supposed to be scoped by the query).
    }
}
```

Two more inits, mirroring existing service conventions: a `convenience init()` reading
`SUPABASE_URL`/`SUPABASE_ANON_KEY` from `Bundle.main` (same as `ZoneMessageService`'s own
convenience init), and a test/preview-only `convenience init(preloadedZones: [Zone])` that never
touches the network — this is what lets every existing `CommunityPinService(...)` test call site
that doesn't care about zones keep compiling unchanged (see §3.2).

**Cache:** `UserDefaults.standard`, one JSON-encoded `[Zone]` blob under `wepark_zones_cache_v1` —
plain device-local storage, no iCloud sync (zones aren't per-user state, no cross-device concern).
**No TTL.** Always attempt a live fetch at cold launch; the cache is read ONLY as the fallback for a
failed fetch, never as a "skip the network" shortcut. Never refetched on foreground/scenePhase —
this is deliberately unlike `updatePushZoneFromParkedCarOrLocation` (which recomputes a *derived*
zone id on every foreground) — the *zone list itself* only ever refreshes once per process lifetime,
per the ruled proposal doc's explicit "fetched once at cold launch, not realtime" contract.

**First-launch-and-offline edge case (no cache, fetch fails):** `zones == []`. This is the doc's own
recommended answer, restated: no compiled-in fallback constants. Every consumer below is already
nil/empty-tolerant (home-zone resolution → `nil`, write-time stamping → omits `zone_id`, map overlay
→ renders nothing, picker → shows an explicit "Couldn't load squares" empty state, never a crash).
Genuinely rare (first-ever launch AND offline) and fully recoverable on the next successful launch.

**⚠️ Load-bearing: `loadZonesIfNeeded()` is called UNCONDITIONALLY, not gated behind
`AppConstants.communityEnabled`.** This is easy to get wrong by copying the adjacent
`if AppConstants.communityEnabled { zoneMessageService.startRealtime() }` line in
`performLaunchSetup()` — don't. `resolveZoneId`'s write-time stamping (§3.2) is **not** flag-gated:
it runs today, in production, for every enforcement/sweeper crowd report any external user submits,
flag on or off (`CommunityPinService.insertCrowdPin` predates Community 2.0 and isn't behind the
flag). Gating the fetch behind the flag would silently regress that already-shipping write path back
to zero zone coverage for flag-off users. The picker/feed UI stays fully flag-gated as before —
only the underlying fetch must not be.

### 3.2 Consumer migration (the 9 call sites)

`CommunityZoneBounds.zoneId(forLat:lng:)` / `.box(for:)` become free functions on a new
`ZoneGeometry` enum (same file as `ZoneStore`), taking an explicit `zones: [Zone]` parameter instead
of reading a compiled table — mechanical signature change, still `nonisolated`, still directly
testable without an instance or `await`:

```swift
enum ZoneGeometry {
    /// Smallest-matching-box wins when a point falls inside more than one zone — the documented
    /// tie-break for the manhattan-zones.md-flagged overlaps (nolita/noho, west-village/chelsea,
    /// etc.). Never mattered at 3 non-overlapping zones; load-bearing at 41.
    static func zoneId(forLat lat: Double, lng: Double, in zones: [Zone]) -> String? {
        zones.filter { $0.contains(lat: lat, lng: lng) }.min { $0.areaApprox < $1.areaApprox }?.id
    }
    static func box(for zoneId: String, in zones: [Zone]) -> Zone? {
        zones.first { $0.id == zoneId }
    }
}
```

Retire `Services/CommunityZoneBounds.swift` entirely. Every call site gets a `zones:` argument
sourced from a `ZoneStore` reference each file already has access to (constructed once in
`ContentView.init`, passed down exactly like `pinService`/`zoneMessageService` today):

| # | File : line | Today | Becomes |
|---|---|---|---|
| 1 | `ContentView.resolveHomeZoneId` (×2 calls) | `CommunityZoneBounds.zoneId(forLat:lng:)` | add `zones: [Zone]` param, pass `zoneStore.zones` at the one call site (`communityHomeZoneId`) |
| 2 | `ContentView.updatePushZoneFromParkedCarOrLocation` (×2 calls) | same | same — reads `zoneStore.zones` directly (no new param, it's a `ContentView` method) |
| 3 | `CommunityPinService.resolveZoneId` (static) | `explicit ?? CommunityZoneBounds.zoneId(...)` | add `zones: [Zone]` param; `insertCrowdPin` (instance method) calls `Self.resolveZoneId(explicit:lat:lng:zones: zoneStore.zones)` — **`insertCrowdPin`'s own public signature is unchanged**, so its ~7 call sites (ReportSheet, ParkedCarDetailView, ContentView, 4 test files) need zero edits |
| 4 | `CommunityPinService.buildLeaderboardRequest` | `CommunityZoneBounds.box(for: zoneId)` | `ZoneGeometry.box(for: zoneId, in: zoneStore.zones)` |
| 5 | `CrewFeedMerge.resolvedZoneId(for:)` | `pin.zoneId ?? CommunityZoneBounds.zoneId(...)` | add `zones: [Zone]` param + the unrecognized-id fallback (see §3.3) |
| 6 | `MapViewRepresentable.Coordinator.syncZoneBoundaries` | `CommunityZoneBounds.box(for: homeZoneId)` then draws + labels it | **parameter itself changes shape**: takes `homeZone: Zone?` instead of `homeZoneId: String?` — `ContentView` resolves the `Zone` once (`zoneStore.zones.first { $0.id == communityHomeZoneId }`) and hands the view the whole object. Removes `MapViewRepresentable`'s `CommunityZoneBounds` dependency AND its own `zoneDisplayName(_:)` static switch (label becomes `zone.name.uppercased()` directly — a strict improvement: "BATTERY PARK CITY" instead of the old default-case's id-derived "BATTERY-PARK-CITY") |
| 7 | `BlockDetailView.resolvedZoneId(forSegmentMidpoint:)` | `CommunityZoneBounds.zoneId(...)` | add `zones: [Zone]` param; `BlockDetailView` gains an optional `zoneStore: ZoneStore? = nil` property, same optional-dependency pattern as its existing `pinService`/`zoneMessageService` |
| — | `MapViewRepresentable.communityZoneIds` (`["nolita","soho","les"]`, one test reference) | dead once `syncZoneBoundaries` no longer needs an id list | delete; update `CommunityS13aTests.swift:317` |

`ContentView` constructs **one** `ZoneStore` instance in `init` (same place `pinService`/
`zoneMessageService`/`pushRegistrationService` are constructed) and threads it to
`CommunityPinService`'s init (new `zoneStore: ZoneStore = ZoneStore()` parameter — defaulted so the
~50 pre-existing test call sites that don't exercise zone behavior compile unchanged; production and
zone-behavior tests pass the shared/fixture instance explicitly), to `CrewFeedSection`, to
`BlockDetailView`, and reads it directly for `resolveHomeZoneId`/`updatePushZoneFromParkedCarOrLocation`/
the `mapRepresentable` computed property.

### 3.3 Zone-id migration semantics

- **Ids are stable → zero data migration**, confirmed by inspection of `06-manhattan-zones.sql`
  (nolita/soho/les rows use `on conflict (id) do update`, never delete/insert-new-id). Nothing to do
  here beyond what's already true.
- **Stored `zone_id` always wins over geometry once set.** `CrewFeedMerge.resolvedZoneId(for:zones:)`
  only recomputes from lat/lng when `pin.zoneId` is `nil` **or** not present in the current fetched
  `zones` list:
  ```swift
  static func resolvedZoneId(for pin: CommunityPin, zones: [Zone]) -> String? {
      if let zoneId = pin.zoneId, zones.contains(where: { $0.id == zoneId }) { return zoneId }
      return ZoneGeometry.zoneId(forLat: pin.lat, lng: pin.lng, in: zones)
  }
  ```
  A pin stamped `zone_id = 'les'` before this migration stays attributed to `'les'` forever, even
  though the new, shrunk `les` box may no longer geographically contain that pin's lat/lng (it might
  now sit inside `two-bridges` or `chinatown`'s new box instead) — this is the manhattan-zones doc's
  own explicit non-breaking guarantee, and the display-time fallback function must never override a
  real stored id to "fix" that. Only a genuinely `nil` or genuinely-unrecognized id triggers
  re-derivation.
- **Cosmetic-only consequence:** the S13a zone-boundary overlay draws whatever box `les` has *today*
  — a pre-migration `les` pin may render visibly outside the post-migration `les` rectangle. No data
  fix needed (documented already); QA should not treat this as a bug if observed.

### 3.4 Nearest-first picker (buildable default)

New pure type, same file as `ZoneStore`:

```swift
enum ZoneOrdering {
    /// Distance from (lat,lng) to a zone's box — 0 if inside, else distance to the nearest
    /// clamped edge point (not the centroid — more honest for large/elongated zones).
    static func distanceMeters(fromLat lat: Double, lng: Double, to zone: Zone) -> Double

    /// Home zone (if resolvable and present) pinned first, unconditionally — not merely a
    /// distance-0 tie, an explicit rule, so float/overlap edge cases never bury it. Remaining
    /// zones ascending by distance; ties (multiple containing boxes, no home zone set) broken by
    /// ascending area — smallest/most-specific first, same rationale as the containment tie-break.
    /// No origin at all (no car, no device location) falls back to alphabetical by name — a
    /// stable order, never raw fetch-order id soup.
    static func orderedZones(zones: [Zone], homeZoneId: String?, originLat: Double?, originLng: Double?) -> [Zone]

    /// The chip row always shows the `limit` nearest zones PLUS the currently-selected zone even
    /// if it fell outside that window (a user who picked something far away from the overflow
    /// sheet must still see it highlighted in the row, not silently un-selected-looking).
    static func visibleChipZones(ordered: [Zone], selectedZoneId: String?, limit: Int) -> [Zone]
}
```

**Origin for both the ordering and home-zone pinning is the same priority `resolveHomeZoneId`
already uses — parked car, else device location, else neither** — so the home zone and the "nearest"
top-of-list zone are almost always the same thing by construction; `visibleChipZones`'s job is the
rare divergence (browsing a zone chip far from home).

**UI shape** (`CrewFeedSection.zoneChipsRow`, replacing the fixed `HStack` over
`CommunityZone.allCases`):
- `ScrollView(.horizontal)` over `ZoneOrdering.visibleChipZones(..., limit: 8)` — same chip visual
  style as today (capsule, bold caption, selected = filled blue). Home zone gets a small leading
  `house.fill` glyph (9pt) so "this one's mine" reads at a glance without new copy.
- A trailing **"More"** chip, shown only when `zoneStore.zones.count > 8` — opens a `.sheet` with a
  `List` of ALL zones (search field at top, filtering by name substring; no query = flat
  nearest-first, not grouped). Tap a row → sets the selection and dismisses.
- **At today's data volume (3 zones, pre-migration), `zones.count > 8` is false — the "More" chip
  never renders, and the visible-chip window shows all 3.** The refactor is byte-for-byte the same
  UX as today until Kevin applies the migration; this is the mechanism behind "zero client changes"
  in the pre/post matrix below.
- Selection state: `@State private var selectedZoneId: String? = nil`, defaulted via a pure
  `ZoneSelectionDefaulting.defaultSelection(currentSelection:orderedZones:)` helper (keeps the
  current selection if it's still valid, else picks `orderedZones.first`) called from `.onAppear` and
  `.onChange(of: zoneStore.zones)` — covers both "zones already cached from a prior launch when this
  view mounts" and "fetch completes while the feed is already open," without ever yanking a still-valid
  selection out from under the user mid-browse (ids are stable across the fetch completing).
- Away-note (`awayZoneNote`) and `LeaderboardPublishGuard` both change `CommunityZone` → `Zone` in
  their signatures; no copy or gating-rule change (works identically for any zone name).
- `CommunityZone` (the 3-case `CaseIterable` enum) is deleted from `CrewFeedSection.swift`.

**Deferred, not this session:** grouping the overflow sheet by area (Downtown/Village/Midtown/etc.,
per the proposal doc's suggestion) — flat nearest-first + search covers the "find my square"
use case without needing to invent/maintain group boundaries. Worth a `@designer` look later if the
flat list feels unwieldy in practice; not blocking.

### 3.5 Pre/post-migration behavior matrix

| | `zones` table today (3 + legacy) | `zones` table after Kevin applies 06 (41 + legacy) |
|---|---|---|
| **Fetch result** | 3 `Zone` objects (soho-les filtered) | 41 `Zone` objects (soho-les filtered) |
| **Crew feed picker (flag on)** | 3 chips, no "More" — identical to today | Up to 8 nearest chips + "More" sheet, home-badged |
| **Write-time `zone_id` stamping (flag off, live today)** | Unchanged from current prod behavior — same 3 boxes, now fetched instead of compiled | A crowd report anywhere in Manhattan now gets a real `zone_id` instead of `null` outside the old 3 tiny boxes — a strict quality improvement, invisible to any UI since nothing flag-off reads `zone_id` back |
| **Push targeting (`device_push_tokens.zone_id`, Edge Function)** | Unaffected — the function treats `zone_id` as an opaque string, `.eq()`-filtered, no hardcoded id list or count anywhere in `send-community-push/index.ts` (verified by reading the file; the one comment mentioning "three NYC neighborhoods" is prose, not logic — §2 Out-of-scope) | Same — genuinely zero server-side change needed either way |
| **Zone-boundary overlay** | Same 3 possible boxes as today | Same code path, now can draw any of 41 |
| **Client code required to move between these two states** | — | **None.** No app rebuild, no TestFlight upload — the fetch is generic over row count |

This is the direct answer to "does anything assume the 3 ids": no server-side code does (checked the
Edge Function and RLS); the only thing that assumed 3 ids was the client's own compiled table, which
this session removes.

## 4. Work streams

**Single `@ios-engineer` session, one PR, built sequentially (not split across parallel agents).**
This feature necessarily touches `ContentView.swift`, `MapViewRepresentable.swift`, and
`CommunityPinService.swift` simultaneously — the three files HANDOFF.md/open-items.md name as the
standing contended-file set that must never be edited by two agents concurrently. There's no safe
seam to parallelize here; sequencing inside the one session:

1. Data layer first, independently testable: `Models/Zone.swift`, `Services/ZoneStore.swift`
   (`ZoneGeometry`, `ZoneOrdering`, cache, fetch). Green tests before touching any consumer.
2. Consumer migration (§3.2's table) — mechanical, one file at a time: `CommunityPinService.swift` →
   `CrewFeedSection.swift`'s non-UI logic (`CrewFeedMerge`, `LeaderboardPublishGuard`) →
   `MapViewRepresentable.swift` → `BlockDetailView.swift` → `ContentView.swift` (wiring/injection,
   touched last since it depends on every other file's new shape existing first).
3. Picker UI (§3.4) — `zoneChipsRow` replacement + the overflow sheet. Last, since it's the only
   piece with real design-judgment risk; the mechanical parts land first so a Mac-gate compile
   failure late in the session doesn't also block on picker bikeshedding.
4. Update the ~5 existing test files this touches (`CommunityZoneStampingTests.swift`,
   `CrewFeedSectionTests.swift`, `CommunityS13aTests.swift`, plus whichever `ContentView`/
   `MapViewRepresentable` test files assert the old signatures) + add the ~3 new test files from §5.

Not involved this session: `@pwa-maintainer` (no PWA surface), `@backend-data` (migration already
written and ruled — nothing left to write), `@designer` (optional, non-blocking per the open decision
at the top).

## 5. Acceptance criteria

- [ ] `Services/CommunityZoneBounds.swift` is deleted; no remaining reference to
      `CommunityZoneBounds` anywhere in `ios/WePark` (production or test code).
- [ ] `ZoneStore.loadZonesIfNeeded()` is called from `ContentView.performLaunchSetup()`
      **unconditionally** (not inside an `if AppConstants.communityEnabled` block).
- [ ] `ZoneStore.fetchZones()` issues `GET rest/v1/zones?select=id,name,lat_min,lat_max,lng_min,lng_max&order=id&id=not.eq.soho-les`
      with an `apikey` header and no `Authorization` header.
- [ ] The decoded zone list never includes `"soho-les"` even if a test server response includes it
      (client-side filter, belt-and-braces).
- [ ] A failed fetch with no prior cache leaves `zones == []`; nothing crashes; `insertCrowdPin`
      omits `zone_id` from the payload in that state (same as today's out-of-bounds-coordinate case).
- [ ] A failed fetch WITH a prior successful cache falls back to the cached list, not an empty one.
- [ ] `CommunityPinService.resolveZoneId(explicit:lat:lng:zones:)`: explicit id always wins; nil
      explicit + point inside exactly one zone → that zone; point inside two overlapping zones →
      the smaller-area zone; point inside none → `nil`; empty `zones` array → `nil` (never crashes).
- [ ] `CrewFeedMerge.resolvedZoneId(for:zones:)`: a pin with a real, still-present `zone_id` returns
      that id unconditionally, even when the pin's lat/lng would resolve to a *different* zone under
      the current box set (the LES-shrink scenario). A pin with a `zone_id` absent from the current
      `zones` list falls back to the lat/lng lookup, same as a `nil` `zone_id` always has.
- [ ] Flag-off crowd-pin submission (enforcement/sweeper via `ReportSheet`) still succeeds end-to-end
      against a live-shaped mock, with `zone_id` correctly populated for a coordinate that would have
      been *outside* all 3 old boxes but inside one of the 38 new ones (proves the write path's
      quality improvement, not just non-regression).
- [ ] Crew-feed picker (flag on, mocked 3-zone fixture): renders exactly 3 chips, no "More" chip —
      pixel/behavior parity with pre-refactor.
- [ ] Crew-feed picker (flag on, mocked 41-zone fixture): renders ≤8 chips + a "More" chip; tapping
      "More" opens a searchable list of all 41; selecting a distant zone from that list both sets the
      feed's selection AND appears in the chip row afterward.
- [ ] Home zone (resolvable from a fixture parked-car coordinate) is always the first visible chip
      and carries the home glyph, regardless of alphabetical or fetch order.
- [ ] `MapViewRepresentable`'s zone-boundary overlay renders any `Zone`'s box/label correctly,
      including a zone whose name isn't one of the original three (e.g. "Hell's Kitchen" renders as
      "YOUR SQUARE · HELL'S KITCHEN", not a raw id).
- [ ] Full existing suite green with the flag off (byte-identical map/UI — no consumer of this
      session's changes is reachable flag-off except the write-path zone stamping, which is covered
      by its own AC above, not a visual AC).
- [ ] Full existing suite green with the flag on (mocked zone fixtures, no live network).

## 6. Test plan

**Pure logic (no network mocks needed):**
- `ZoneGeometryTests` (replaces/extends the existing `ResolveZoneIdTests` in
  `CommunityZoneStampingTests.swift`): containment single-match, containment tie-break by area,
  no-match, boundary-inclusive edges, `box(for:)` unknown id, `resolveZoneId` with an empty `zones`
  array.
- `ZoneOrderingTests` (new): home-zone pinned first even under a distance tie; ascending-distance
  sanity check; area tie-break with no home zone; no-origin alphabetical fallback;
  `visibleChipZones` appends an out-of-window selected zone; `visibleChipZones` needs no "More" when
  `zones.count <= limit`.
- `ZoneSelectionDefaultingTests` (new): keeps a still-valid selection; re-defaults when the current
  selection id vanished from a fresh fetch; defaults to `orderedZones.first` from nil.
- `CrewFeedMergeZoneTests` (extends `CrewFeedSectionTests.swift`): stored-id-wins-over-geometry
  (the LES-shrink case, explicit fixture); unrecognized-id falls back to lat/lng; nil-id unchanged
  behavior (regression guard on the existing case).

**Wire-shape (this repo's established PostgREST-request-shape convention, per
`ZoneMessageServiceTests.testFetchMessages_requestIncludesZoneIdFilter` /
`testFetchMessages_noAuthorizationHeader_apiKeyPresent`):**
- `ZoneStoreTests`: request URL contains `select=id,name,lat_min,lat_max,lng_min,lng_max`,
  `order=id`, `id=not.eq.soho-les`; `apikey` header present, `Authorization` header absent; 3-row and
  41-row fixture decode correctly (snake_case → camelCase field mapping); non-2xx sets `fetchError`
  and leaves `zones` unchanged; cache round-trip (`save` then `load` returns an equal array);
  `loadZonesIfNeeded` falls back to cache on a failed fetch.
- `InsertCrowdPinZoneStampingTests` (existing file, updated): construct `CommunityPinService` with
  an explicit `zoneStore: ZoneStore(preloadedZones: fixtureZones)` instead of relying on the old
  hardcoded table, so the existing lat/lng fixtures keep asserting the same zone-membership outcomes.
- `CommunityPinServiceTests` (leaderboard request shape): `buildLeaderboardRequest` still queries the
  correct bounding box when given a `Zone` fetched from a non-original zone id (e.g. `"chelsea"`).

**Mac gate (not unit tests — see ceremony below):** live `xcodebuild test` run, flag-off crowd-report
smoke against a mocked-then-real zone list, flag-on picker visual check via simulator Custom Location.

## 7. Migration ceremony — sequenced, and how to verify without being in NYC

Per the roadmap: **client-first, migration-second.** None of this needs Kevin in Manhattan — every
verification step below is either a `curl` against Supabase or a simulator with a spoofed location
(Xcode → Debug → Location → Custom Location, standard feature, no GPS/real drive required).

1. `@ios-engineer` builds this spec on the VPS worktree (`[COMPILE-UNVERIFIED]`, per convention).
2. `@qa-verifier` static/logic pass against §5's acceptance criteria; fix-then-merge on any blocker.
3. **Kevin's Mac gate — BEFORE the migration, against the CURRENT 3-zone prod table:**
   - `xcodebuild test`: full suite green (mocked fixtures — no live network needed for most of it).
   - Flag OFF (shipped default): submit a crowd report from the simulator at any Custom Location
     inside Manhattan but outside the old 3 boxes (e.g. Chelsea) → confirm via a
     `curl ".../rest/v1/pins?select=id,zone_id&order=created_at.desc&limit=1" -H "apikey: $ANON_KEY"`
     that `zone_id` is still `null` at this point (migration hasn't landed yet — this is the
     "before" baseline, not a bug).
   - Flag ON, **local-only flip, never merged** (same "Option B" pattern already used for TestFlight
     archives per the roadmap S12 row): open the crew feed → confirm exactly 3 chips, no "More" chip
     — the parity check. Set Custom Location to a known Nolita coordinate → confirm the Nolita chip
     is first and home-badged. Revert the local flag flip before anything is committed.
4. Merge the client PR to `main` (flag stays `false` in the merged code).
5. **Kevin applies `supabase/06-manhattan-zones.sql`** in the Supabase SQL editor (per standing
   convention — agents never touch production schema).
6. Kevin verifies the migration landed, no app or Mac needed:
   `curl "$SUPABASE_URL/rest/v1/zones?select=id,name&order=id" -H "apikey: $ANON_KEY"` → expect 42
   rows (`soho-les` + `nolita` + `soho` + `les` + 38 new).
7. Kevin verifies the **client** picked it up, still with zero new app build:
   - Force-quit and cold-relaunch the already-installed build (simulator or TestFlight phone) —
     triggers the unconditional fetch.
   - Live write-path check (flag stays off, no app UI change to look for): submit a crowd report
     from a Custom Location outside the old 3 boxes (e.g. Chelsea again) → the same `pins` curl now
     shows `zone_id = "chelsea"`, not `null`. This alone confirms 41-zone data is live and being
     consumed, without needing the flag on or Kevin's phone anywhere near Manhattan.
   - Picker visual check (needs the SAME local-only flag flip as step 3, since `communityEnabled`
     is still `false` on the TestFlight binary until the drive-test gate): open the crew feed →
     confirm ≤8 chips + a "More" chip, and that "More" opens a searchable 41-zone list. Set Custom
     Location to a few different boroughs-worth of test points (Harlem, West Village, Financial
     District) and confirm the nearest-first order visibly changes each time.

## 8. Out-of-scope follow-ups

- True polygon/point-in-polygon zone geometry (OQ-1, already documented as the eventual upgrade
  path in the reconciliation spec and the manhattan-zones doc) — only worth doing if boxes visibly
  misclassify blocks in practice.
- Grouped-by-area browsing in the overflow sheet — shipped flat nearest-first + search instead;
  revisit with `@designer` if the flat list proves unwieldy at 41 rows in practice.
- The Edge Function's stale "three NYC neighborhoods today" comment
  (`supabase/functions/send-community-push/index.ts:98`) — cosmetic, confirmed zone-count-agnostic
  logic, not worth a redeploy alone; fold into the next real touch of that function.
- North-of-96th-St coordinate spot-checking against Google Maps/OSM — this is Kevin's own
  pre-apply diligence step on the migration doc itself, not engineering scope for this session.
- Visual polish on the home-zone chip glyph / overflow-sheet styling to more precisely match
  hero-parity conventions — this spec's default is functional, not a hero-parity pass.
