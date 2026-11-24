# Address-anchored parking ("In front of 123 E 1st St")

Status: DRAFT for Kevin. Author: Tech Lead. 2026-11-23.
Inputs: Kevin 2026-11-23 ("use addresses to lock the car in ... the exact position of the pin could be relative"), `docs/qa/curbpin-snap-diagnosis-2026-11-23.md` (Address-anchoring inventory, lines 107-116), PR #157 (curb-pin snap fix, in flight), PR #156 (cross-street line routed through `titleCased`).

## 0. Decisions needed from Kevin (read first)

1. **Confirm MVP = MapKit reverse geocode on-device, display + store only** (no tile/pipeline change). Pipeline address ranges (PAD/LION) are Phase 2. Recommended.
2. **Label honesty.** OK to show "Near 123 E 1st St" when we cannot prove the number is on the snapped curb side, and "In front of" only when verified? Recommended yes.
3. **Does the address ever leave the phone?** Recommended: no. Only iCloud KVS (your own iCloud) and local notifications. Share-my-spot is user-initiated. A future feature that needs it must opt in explicitly; `qr-spot-handoff.md` does NOT send it.

Everything else below is decided here; push back only if you disagree.

## 1. Problem and user story

Today the parked car is a lat/lon plus segment id, side, street, from/to (`ios/WePark/WePark/Models/ParkedCar.swift:37-83`). The PR #157 diagnosis shows the pin is fragile to fight with (needle snap, drag-settle fights). People do not remember "40.7261, -73.9833"; they remember "in front of 123 E 1st". Kevin's position: the address is the human anchor, the pin position is relative to it.

Story: I park, the card says "In front of 123 E 1st St". Later the parked-car sheet, my reminder notification, and "share my spot" all say that. If I drag the pin, the address updates or disappears; it is never stale.

## 2. Scope

In (Phase 1, MVP):
- Reverse geocode at the committed (snapped) curb point, validated against the snapped blockface; store the result on `ParkedCar`.
- Display on placement card, parked-car sheet, local notifications, share-my-spot text.
- DISPLAY-ONLY street-name formatter restoring ordinals (section 6) for every user-facing street string. Approved by Kevin.
- Cache, throttle, offline behavior, VoiceOver, tests, dark-ship flag.

Out (deferred):
- PAD/LION address ranges in tiles (Phase 2, section 9).
- Search/navigate by address; building names / POIs.
- Any server storage of the address.
- Changing `StreetNameNormalizer.canonical` (matching key, mirrors PWA JS).
- Changing curb-snap thresholds (owned by #157).

## 3. Architecture

iOS only for Phase 1. No Backend, no PWA.

New files (suggested): `Services/ParkingAddressResolver.swift` (actor), `Models/ParkingAddress.swift`, `Services/StreetNameFormatter.swift` (pure, nonisolated).

### 3.1 Data source: MapKit now, PAD later
| Option | Pros | Cons |
|---|---|---|
| MapKit reverse geocode (MVP) | zero pipeline work; real postal addresses | needs network; returns nearest address, which may be the OPPOSITE side or a corner/adjacent street; Apple rate limit |
| PAD/LION ranges per blockface in tiles (Phase 2) | offline; deterministic; parity/side solved by data; tied to the legal blockface | backend pipeline + tile size growth; interpolated estimate, not a real building |
| Both (end state) | tile ranges give offline estimate and validate MapKit | most work |

MVP: MapKit only. Deployment target is iOS 17.0 (`project.pbxproj`), so use `CLGeocoder.reverseGeocodeLocation` behind a small `ReverseGeocoding` protocol; the engineer may use `MKReverseGeocodingRequest` under `#available(iOS 26, *)`. The protocol lets tests inject a fake.

### 3.2 Parity and side: geocode the building side, not the curb
A geocode exactly on the curb is a coin flip between both sides. Rule:
1. Probe point: from the snapped curb point step **8 m perpendicular to the blockface axis, away from the roadway centerline** (toward the buildings on the snapped side). `CurbSnapResult` has the polyline/side/`positionFraction` (`CurbSnapIndex.swift:119-140`). Geocode the probe.
2. Validate:
   - Street match: `StreetNameNormalizer.canonical(result.thoroughfare) == canonical(snap.street)`. Mismatch (corner building facing the avenue) => retry once at fraction +-0.15 (clamped 0.05-0.95); still mismatch => `blockOnly`.
   - Number present and parseable (leading digits; "123-125" uses the first; "123A" keeps it).
   - Parity: do NOT hardcode odd/even-by-compass-side (varies by borough/street). Learn it: if a verified address already exists in the cache for the same blockface+side, the new number must share its parity, else demote to `approximate`. Phase 2 PAD makes this authoritative.
   - Distance: placemark location within 40 m of the probe, else demote.
3. Confidence tiers:
   - `verified`: street match + number + (parity consistent or no prior) + within 40 m. Copy "In front of 123 E 1st St".
   - `approximate`: street match + number but parity conflict, far placemark, or found via offset retry. Copy "Near 123 E 1st St".
   - `blockOnly`: no number. Today's copy; no address line.

### 3.3 Accuracy, fallback, offline, rate limits
- Triggers: (a) placement settle/commit, debounced 600 ms after the snap stops changing; never during a live drag; (b) `ParkPinService.save` if the car has no address (auto-detected park, car synced from an older build); (c) one retry on next foreground after an offline failure. Never blocks saving; the line shows a skeleton then fades in.
- Cache: key `segmentID + side + round(positionFraction, 0.1)`, in-memory LRU of 200 only (location-adjacent data is not persisted beyond the ParkedCar).
- Throttle (Apple limits to roughly 50 requests/min/app): 1 in flight, max 6/min, 10 s timeout; on network/no-result/throttle errors back off 30 s and degrade to `blockOnly`. No retry loops.
- Offline / no result: no address line, no error UI, no toast; the card looks like today; VoiceOver silent.
- Never log addresses (no print/analytics).

### 3.4 Interaction with the curb snap
- **Legal anchor unchanged**: `detectedSegmentID` + side drive rules and notification relevance. The address never changes which blockface rules apply; a geocode naming a different street is discarded, never re-snapped.
- **Human anchor**: the address labels the same point. If a drag moves the snap to another blockface/side/fraction bucket, invalidate and re-resolve; show nothing until it resolves (never the stale one).
- PR #157 (no post-drag nudge, 15 m acquire): hook the same "snap committed" event (`CurbPlacementController.settle()` outcome / Park-here save of `snappedCoordinate`); add no map nudge or camera move. No-curb state (>15 m): no address. Build on `main` after #157 merges; the only shared files are `CurbPlacementController` / `CurbPlacementCard`.
- Phase 3: "relative pin" = store fraction + address so a re-snap after tile updates keeps the address stable.

## 4. Storage on ParkedCar
Add `address: ParkingAddress?`:
```swift
struct ParkingAddress: Codable, Equatable {
    var houseNumber: String       // "123", "123A"
    var streetDisplay: String     // as geocoded; passes through StreetNameFormatter at display
    var confidence: Confidence    // .verified | .approximate
    var source: Source            // .mapkit (Phase 2 adds .pad)
    var resolvedAt: Date
}
```
- Backward compatible: the existing custom `init(from:)` uses `decodeIfPresent`; missing key => nil; nil is omitted on encode. Older builds ignore the unknown key, so mixed-build iCloud KVS sync is safe (fixture tests both ways).
- Persisted with the car in iCloud KVS (`Services/ParkPinService.swift`); `remoteCarChanged` merge must carry it; "address filled in later" is the same `id`, not a new car.
- Account deletion: nothing server-side to delete.

## 5. Where it shows
| Surface | Copy |
|---|---|
| Curb placement card (`Views/CurbPlacementCard.swift:306` title area) | title unchanged ("E 1st St . N side"); new secondary line "In front of 123 E 1st St" / "Near 123 E 1st St"; "between X & Y" stays |
| Parked-car sheet | address headline above rules; blockface line stays |
| Local notifications (`NotificationScheduler`) | address only when `verified`, placed in the body variant hidden when previews are off (`hiddenPreviewsBodyPlaceholder`); lock-screen default stays block text |
| Share-my-spot (explicit tap) | "Parked in front of 123 E 1st St (WePark)" + map link |
| Map pin / drive mode / widgets | none in this slice |

VoiceOver: "Parking in front of 123 East 1st Street" (formatter, then expand St/E/W/Ave for the AX label only); approximate: "Near 123 East 1st Street, number approximate". One polite announcement on resolution, not on every re-resolve.

## 6. Display-only street-name formatter (approved addition)

Problem: normalized names lose ordinals ("E 1 St", "W 42 St", "1 Ave"); `StreetNameNormalizer.canonical` (`Services/StreetNameNormalizer.swift:17`) is a matching key mirrored in the PWA JS. **Do not modify `canonical`.** New pure `StreetNameFormatter.display(_:)` is the last step on top of the existing `titleCased` display path (`Views/CurbPlacementCard.swift:347`; PR #156 routed the cross-street line through it). It applies to every user-facing street string: placement card title and "between X & Y", parked-car sheet (street/from/to), address line, notifications, share text, and AX labels.

Rules:
1. Tokenize on whitespace. A token of 1-3 digits is ordinalized when a street-type word follows (`St, Street, Ave, Avenue, Pl, Place, Rd, Road, Blvd, Dr, Drive, Ln, Way, Ct, Sq, Pkwy, Ter, Terrace`). This covers "E 1 St" and a leading "1 Ave".
2. House numbers are never passed in: the address path formats `houseNumber` and street separately. Contract: never feed "123 E 1 St" as one string.
3. Suffix: n mod 100 in 11...13 => "th"; else n mod 10: 1 "st", 2 "nd", 3 "rd", else "th".
4. Already-ordinal tokens are kept, suffix lowercased ("42ND" => "42nd").
5. Not ordinalized: numerics with no street-type follower ("Pier 40", "Route 9"), "Avenue A", tokens >3 digits, "0".
6. Directionals (E/W/N/S) and abbreviations are untouched ("Ave" stays "Ave").
7. Idempotent.

Test cases (`StreetNameFormatterTests`):
| In | Out |
|---|---|
| "E 1 St" | "E 1st St" |
| "W 42 St" | "W 42nd St" |
| "1 Ave" / "2 Ave" / "3 Ave" / "4 Ave" | "1st Ave" / "2nd Ave" / "3rd Ave" / "4th Ave" |
| "E 11 St" / "E 12 St" / "E 13 St" | "E 11th St" / "E 12th St" / "E 13th St" |
| "W 21 St" / "W 22 St" / "W 23 St" | "W 21st St" / "W 22nd St" / "W 23rd St" |
| "E 101 St" / "E 111 St" / "E 112 St" / "E 113 St" | "E 101st St" / "E 111th St" / "E 112th St" / "E 113th St" |
| "E 42ND St" | "E 42nd St" |
| "Avenue A" / "Ave A" | unchanged |
| "Pier 40" | unchanged |
| "Broadway", "Bowery", "FDR Dr", "Houston St" | unchanged |
| display(display(x)) | == display(x) |
Plus regression: `StreetNameNormalizer.canonical` outputs unchanged for the same inputs.

## 7. Privacy
- Where you parked is sensitive (often near home). The address lives only on-device and in the user's own iCloud KVS (same trust as today's coordinates). Never sent to Supabase, analytics, or push payloads. The geocode request itself goes to Apple with the curb coordinate, no identity; add a line to `docs/privacy-policy.md` and check the App Store privacy answers (Precise Location already declared).
- The existing invariant (server never learns the parked blockface; relevance decided on-device, `send-community-push`) is untouched.
- Share-my-spot only on explicit user tap. Lock-screen: section 5.

## 8. Work streams
| # | Stream | Owner | Depends on |
|---|---|---|---|
| A | `StreetNameFormatter` + tests + wire into all street strings | @ios-engineer | none (merge after #156) |
| B | `ParkingAddress` model, `ParkedCar` backward-compatible decode, KVS merge tests | @ios-engineer | none |
| C | `ParkingAddressResolver` (probe geometry, validation, cache, throttle, fake geocoder) | @ios-engineer | B |
| D | UI wiring: card line, parked-car sheet, notification body, share text, VoiceOver | @ios-engineer | A, B, C; rebase after #157 |
| E | Design review: card line states (skeleton / verified / approximate / none) incl. AX sizes | @designer | D draft |
| F | Privacy-policy line + App Store privacy note | Tech Lead doc / @pwa-maintainer if the policy page is hosted | none |
| G | Device QA on real NYC blocks | @qa-verifier | D |
| P2 | PAD/LION pipeline | @backend-data | independent; own spec |
Parallel: A, B, F run concurrently (A and B are separate small PRs); then C, D. Backend neither blocks nor is blocked in Phase 1. Dispatch ios work with all six Swift compile-failure classes cited (qualify `WePark.Category` in tests).

## 9. Phasing
- **Phase 1 (MVP)**: sections 3-7. Flag `AppConstants.addressAnchoredParkingEnabled = false` (`Services/Constants.swift`, beside `curbPinPlacementEnabled`). The formatter (stream A) ships ungated: it only improves strings.
- **Phase 2**: @backend-data derives per-blockface `lowOdd/highOdd/lowEven/highEven` from NYC PAD/LION into tiles (measure tile-size budget first); client interpolates by `positionFraction`; offline estimate; authoritative parity; validator for MapKit (`source: .pad`, copy "Near the 120s block of E 1st St"). Own spec.
- **Phase 3**: relative pin (fraction + address), address-search goal.

## 10. Acceptance criteria
- [ ] Flag off: no behavior change except ordinals in street strings.
- [ ] Flag on, online: pin in front of a known address on E 1st St shows "In front of N E 1st St" with N on that side (manual on 5 blocks: corner, avenue-facing, mid-block).
- [ ] Corner building facing the avenue never shows the avenue's number under the street; falls back to retry then block only.
- [ ] Offline: no address, no error UI, car saves instantly; fills in after reconnect + foreground.
- [ ] Dragging to another blockface invalidates and re-resolves; stale address never shown on the new block.
- [ ] No geocode during an active drag; max 1 in flight, 6/min (fake-clock unit test).
- [ ] Pre-feature saved JSON decodes with `address == nil`; new JSON decodes on an old-shape struct; iCloud remote change keeps the address.
- [ ] Notification shows the address only for `verified`; placeholder when previews off.
- [ ] No `address` in any Supabase request body (URLSession protocol test).
- [ ] VoiceOver spoken form correct; one polite announcement; AX5 layout OK.
- [ ] Formatter table passes (11/12/13, 111-113, 21-23); `canonical` regression passes.
- [ ] Address resolution causes no camera nudge/map move.
- [ ] Share text includes the address only when the user taps share.

## 11. Test plan
- Unit: `StreetNameFormatterTests`; `ParkingAddressResolverTests` (fake geocoder: match, mismatch+retry, parity conflict, no result, throttle, timeout, cache hit); probe geometry for N/S/E/W and a diagonal Houston-shaped blockface; `ParkedCarCodableTests` (old fixture, new fixture, round trip).
- Integration: settle => exactly one resolver call; drag => none.
- Manual (QA, device): 5 NYC blocks, offline, VoiceOver, AX3+.

## 12. Out-of-scope follow-ups
- PAD/LION ranges: needs pipeline + tile budget; MapKit gives the visible win now.
- `ContentView.oppositeSideSegment` ("Both curbs") still uses cross-street pairing (flagged in #157).
- POI/building names: noisy; revisit after addresses land.
- Server-side address use: needs a privacy review; none planned.
