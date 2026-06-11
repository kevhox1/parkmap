# TF2-7: Simplified Cruise Guidance + Sign-Check Confirmation Flow

**Status:** Spec — awaiting Kevin resolution of OQ-1 before code starts.
**Author:** @tech-lead
**Date:** 2026-06-11
**Target build:** TF2 (post-TF1 live; no urgency blocker, safe to queue after supabase-swift SDK)
**iOS only.** PWA in maintenance mode. No backend changes. No tile changes.

**Depends on:**
- Cruise Mode merged (PR #38, `a4c6953`) — `DriveModeStyle`, `CruiseVoicePolicy`, `setCruiseMode(_:)` all on main.
- `ParkConfirmView` (W5/W7, `Views/ParkConfirmView.swift`) — the sign-check sheet inserts here.
- `FAQHelpView` (PR #45, `Views/FAQHelpView.swift`) — copy consistency anchor.

**Related specs:**
- `docs/cruise-mode-spec.md` — the upstream Drive Mode voice architecture this spec revises.
- `docs/w8.5c-drive-mode-active-spec.md` — `DrivingContextService`, `buildUtteranceText`, `speakContext`.
- `docs/w5-pin-drop-spec.md` — `ParkConfirmView` flow this spec extends.

---

## §0 — Open Questions for Kevin — Surface These First

| # | Question | Options | Recommendation |
|---|---|---|---|
| OQ-1 | **Sign-check checklist: shown every time or dismissible "don't show again"?** | (a) Always shown — keeps the novice-safety intent intact; a returning user taps through in ~2s. (b) Shown 3 times then offers "Don't show again" — reduces friction for experienced parkers. (c) Permanent dismiss via a "Don't show this checklist" checkbox at the bottom of the sheet. | **(a) Always shown**, but make it fast — the checklist is 5 items with simple checkboxes; a practiced user taps "Confirm" in under 3 seconds. The educational value for novices who just drove in is high, and the frequency is low (once per park session). Option (b) adds UserDefaults state, an expiry model, and a "reset" affordance in Settings — complexity that is not worth it for 5 checkbox items. Recommend Kevin confirms before code starts since it is a product philosophy decision. |
| OQ-2 | **"Park here" button: appears at all speeds in Cruise Mode or only when stopped/slow?** | (a) Available any time Drive Mode is active (same as the existing "End Drive" pill and Report button — no speed gate). (b) Only appears when GPS speed falls below ~5 mph (~2.2 m/s), i.e., the driver has pulled over. | **(a) No speed gate.** Speed-gating adds complexity (a new `@State` or `CLSpeed` comparison on every location update) for a minor UX gain. The user is already stopped if they want to confirm they parked; there is no harm in the button being tappable while slow-rolling. Parking-hunt speeds are often below 2 m/s anyway (DRIVING_HEADING_MIN_SPEED_MPS = 0.5 in `LocationService`). The W8.5d arrival prompt is also always available (no speed gate) — consistency with that pattern. |

---

## §1 — Problem and User Story

**Drive-testing diagnosis (verbatim from Kevin):** The current voice callouts are too granular to parse at the wheel. A single block can have no-parking, then a metered stretch, then free — the voice announces each segment-level state, producing a rapid sequence of distinct callouts that is hard to act on while driving. The driver needs a single sentence that answers "can I park on this block at all?" — not a zone-by-zone breakdown.

**User story A (cruise/drive guidance):**
> As a driver circling for parking in Find Parking mode, I want to hear a single clear sentence per block — e.g. "Free parking sections on the left — check signs" — rather than a segment-by-segment read-out, so I can react quickly and safely without deciphering multiple data points while driving.

**User story B (sign-check confirmation):**
> As a driver who has just stopped the car, I want a quick checklist that confirms I am legally parked — fire hydrant distance, driveways, bus stops, the posted sign — before I drop my pin, so I don't get a ticket because I missed something obvious.

**Why now:** TF1 is on Kevin's phone. Drive-test feedback is live. This is the first spec triggered by real-device driving. The voice changes are a direct response to Kevin's drive-test experience. The sign-check sheet is the natural complement — the app gets the driver to the right block; the checklist closes the loop.

---

## §2 — Scope

### 2.1 In scope

1. **Side-level catch-all aggregation function** — a new pure function `parkingSideLabel(segments:forStreet:from:to:side:heading:date:engine:) -> SideOpportunity` that reduces a side's multi-segment rule set to a single top-level label (`free`, `metered`, `restricted`, `unknown`) for voice + card. See §3.
2. **Revised voice copy in `CruiseVoicePolicy.utteranceText`** — replace the current per-severity phrasing with the catch-all template including the "check signs" qualifier. The function signature and call site in `DrivingContextService` are unchanged; only the returned string changes. See §4.
3. **Revised voice copy in `DrivingContextService.buildUtteranceText`** — destination mode also gets the simplified phrasing (same catch-all template; Kevin's direction was not limited to Cruise Mode). See §4.
4. **`DriveModeBottomCard` card text** — the left/right chip `SafetyLabel.text` in the chip is the natural display of the aggregated label. No structural change to `DriveModeBottomCard.swift` is needed; the simplification flows from the `SafetyLabel` produced by the aggregation function. A doc-comment update noting the side-level aggregation is the intended input is useful but not blocking.
5. **"Park here" button in the drive overlay** — a new primary-action button inside `driveModeOverlayLayer` in `ContentView.swift`, visible whenever `driveModeActive == true`. On tap: builds a `PinDropIntent` from `locationService.userLocation`, then opens a NEW `ActiveSheet.signCheckConfirm(intent: PinDropIntent)` case. See §5.
6. **`SignCheckConfirmView`** — a new sheet at `Views/SignCheckConfirmView.swift`. Content: 5-item checklist + confirm CTA that drops the pin and proceeds into the existing `ParkConfirmView` flow. See §5.
7. **New `ActiveSheet.signCheckConfirm(intent: PinDropIntent)` case** — inserts between the "Park here" tap and `ParkConfirmView`. The confirm CTA inside `SignCheckConfirmView` dismisses itself and opens `ActiveSheet.parkConfirm(intent)`, which is the existing `ParkConfirmView`. See §5.3.
8. **Tests** — unit tests for the aggregation function; a copy-string smoke test for voice templates; no new UI tests. See §7.

### 2.2 Out of scope (explicitly deferred)

- **New tile data or backend changes.** The aggregation function operates entirely on the already-loaded `[Segment]` slice for the current block. No new tile fields, no Supabase calls.
- **PWA.** Maintenance mode.
- **Destination mode voice calibration (timing constants).** W8.5c-follow is the home for voice cadence calibration. This spec changes copy only, not gap constants.
- **Per-segment minimum length filtering in voice output.** The 6-meter minimum-free-stretch threshold (§3.3) applies to the aggregation function's classification decision. If a side is classified `.free`, voice says "Free parking sections on the left — check signs." The app does not attempt to announce the length of the free stretch.
- **"Shown n times" dismiss logic for the sign-check sheet.** OQ-1 is resolved as always-shown pending Kevin's confirmation (§0).
- **Sign-check content integration with the map.** The checklist items are static educational text; no GPS proximity check for fire hydrants or bus stops is attempted.
- **ASP day-check integration.** The checklist includes an ASP reminder as a static text item only. It does not re-invoke `ASPSuspensionService` — the live ASP banner already shows that information at the top of the screen.

---

## §3 — Side-Level Aggregation

### 3.1 The granularity problem

`DrivingContextService.update(...)` currently finds `leftSeg` and `rightSeg` by picking the *single closest segment* on each side of the current block via `findSegment(street:from:to:side:in:)`. It then calls `engine.safetyLabel(for:)` on that one segment. The resulting `SafetyLabel.text` for a mixed block (e.g., one no-parking zone at the corner + a free zone in the middle) is the label for whichever segment happens to be geometrically closest to the driver's GPS fix at that moment — which may be "No parking" even when half the block is free. This is the source of the "zone-by-zone" confusion Kevin experienced.

The fix is a side-level aggregation: given all segments on a given side of the current block, produce one `SideOpportunity` enum value that answers "is there *any* free stretch on this side, or metered, or is the whole side restricted?"

### 3.2 `SideOpportunity` enum

The aggregation function returns a typed result:

```
// Pseudocode — not production Swift
enum SideOpportunity {
    case free          // at least one qualifying free stretch exists (≥ minimumFreeLength)
    case metered       // no qualifying free stretch; at least one metered segment exists
    case restricted    // no free or metered segments — entire side is restricted or no-standing
    case unknown       // no segments found for this side (data gap)
}
```

**Mapping to voice + card:**
- `.free` → voice: "Free parking sections on the [left/right] — check signs." Card chip: existing `SafetyLabel(text: "Free — check signs", severity: .free)`.
- `.metered` → voice: "Metered on the [left/right]." Card chip: `SafetyLabel(text: "Metered", severity: .metered)`.
- `.restricted` → voice: omitted (the Cruise Mode `shouldAnnounce` gate already filters all-restricted blocks). Card chip: `SafetyLabel(text: "No parking", severity: .restricted)`.
- `.unknown` → voice: omitted. Card chip: `SafetyLabel(text: "—", severity: .unknown)`.

### 3.3 Minimum free stretch length

**Threshold: 6 meters (approximately one car length).**

Rationale: A free stretch shorter than one car length is not actionable — the driver cannot legally fit. 6 meters is the setback already used in the tile geometry pipeline (PR #21 — the intersection-clip setback constant). Reusing the same threshold avoids a new magic number and aligns with the tile data's existing precision floor. A half-block threshold (~30 meters) was considered but would classify many mixed blocks as metered even when they have a workable free zone, defeating the purpose.

**Implementation:** The aggregation function measures each free segment's length using the haversine distance between the first and last coordinates in `segment.line`. If the segment length is ≥ 6 meters and the engine classifies it as `.free`, it counts as a qualifying free stretch.

### 3.4 Left/right determination for one-way streets

One-way segment data (`Segment.oneway`, `Segment.onewayToward`) is available from the FT-11 tile pipeline (merged via `1254da5`). On a one-way street, the driver can only approach from one direction, so left/right is deterministic from the oneway heading. The aggregation function receives the driver's travel heading via the existing `heading: CLLocationDirection?` parameter and uses the existing `sideRelativeToHeading(heading:side:)` logic already in `DrivingContextService` — no new heading math is needed.

### 3.5 Function signature (pseudocode for the spec — not production Swift)

```
// New static helper — lives in DrivingContextService (or a new file SideAggregator.swift)
static func aggregateSide(
    segments: [Segment],      // all segments for the current street/from/to combination
    side: String,             // "N", "S", "E", or "W" — the cardinal side to classify
    engine: ParkingRulesEngine,
    date: Date,
    minimumFreeLength: Double = 6.0  // meters; injectable for unit tests
) -> SideOpportunity
```

**Pure function contract:** no side effects, no stored state, no framework imports. Testable at zero cost. Mirrors the `CruiseVoicePolicy` / `FinalApproachService` pattern.

**Algorithm:**
1. Filter `segments` to those matching the given cardinal `side`.
2. For each matching segment, call `engine.safetyLabel(for: segment, at: date)`.
3. If any segment has severity `.free` AND its haversine length ≥ `minimumFreeLength` → return `.free` immediately (short-circuit).
4. If no `.free` found but any segment has severity `.metered` → return `.metered`.
5. If segments were found but none were free or metered → return `.restricted`.
6. If no segments matched the side → return `.unknown`.

**Step 3 short-circuit justification:** "any free stretch ≥ one car length" is the product requirement. Once one is found, the side is classified `.free` regardless of how many restricted zones also exist on that side.

### 3.6 Integration point in `DrivingContextService.update`

The aggregation replaces the current single-segment lookup:

Current path (lines 228-230 of `DrivingContextService.swift`):
```
let leftLabel  = leftSeg.map  { engine.safetyLabel(for: $0, at: date) } ?? noData
let rightLabel = rightSeg.map { engine.safetyLabel(for: $0, at: date) } ?? noData
```

New path (conceptual — not production Swift):
```
let leftOpp  = DrivingContextService.aggregateSide(segments: segments, side: leftCardinalSide,  engine: engine, date: date)
let rightOpp = DrivingContextService.aggregateSide(segments: segments, side: rightCardinalSide, engine: engine, date: date)
let leftLabel  = SafetyLabel(for: leftOpp)
let rightLabel = SafetyLabel(for: rightOpp)
```

Where `leftCardinalSide` and `rightCardinalSide` are the cardinal sides ("N"/"S"/"E"/"W") that map to left/right given the current heading — these are derived from the existing `sideRelativeToHeading` loop result. The `leftSeg`/`rightSeg` variables in the current code already perform this mapping; the new code passes the resolved cardinal side strings to `aggregateSide` instead.

The existing `DrivingContext` struct remains unchanged (it still carries `leftLabel: SafetyLabel` and `rightLabel: SafetyLabel`). The aggregation outputs are wrapped into `SafetyLabel` values before being stored in `DrivingContext`. No downstream consumer — `DriveModeBottomCard`, `CruiseVoicePolicy`, `buildUtteranceText` — needs to know about `SideOpportunity`; they continue to receive `SafetyLabel` as today.

---

## §4 — Voice + Card Copy

### 4.1 Copy strings (exact)

The following are the exact strings the spec mandates. `@ios-engineer` must match these character-for-character in both `CruiseVoicePolicy.utteranceText` and `DrivingContextService.buildUtteranceText`. QA will verify against these strings in acceptance criterion TF2-7.6.

**When left side is `.free`:**
```
"[StreetName]. Free parking sections on the left — check signs."
```
Example: `"Spring Street. Free parking sections on the left — check signs."`

**When right side is `.free`:**
```
"[StreetName]. Free parking sections on the right — check signs."
```

**When both sides are `.free`:**
```
"[StreetName]. Free parking sections on both sides — check signs."
```

**When left is `.free`, right is `.metered`:**
```
"[StreetName]. Free parking sections on the left — check signs."
```
Rationale: the free side is the actionable lead. The metered detail is visible on the card chip; voice is the action cue, not a data read-out.

**When no free on either side; left is `.metered`:**
```
"[StreetName]. Metered on the left."
```

**When no free on either side; right is `.metered`:**
```
"[StreetName]. Metered on the right."
```

**When no free on either side; both `.metered`:**
```
"[StreetName]. Metered on both sides."
```

**When both sides `.restricted` or `.unknown`:** No voice announcement (existing `CruiseVoicePolicy.shouldAnnounce` gate already suppresses this case in Cruise Mode; destination mode now also suppresses it via the aggregation — see §4.3).

### 4.2 The "might not be everywhere" decision

Kevin's requirement: convey partial coverage without re-introducing complexity.

**Recommended phrasing: "Free parking sections on the left — check signs."**

The word "sections" does the work: it implies partial, not universal. The "— check signs" qualifier reaffirms the posted signs as the final word (consistent with `FAQHelpView`'s existing language: "the sign on the street is always the final word"). The full sentence is 9–10 words, well within the cognitive budget for a driving voice cue.

Alternatives considered:
- "Free parking on parts of the left" — "parts" is casual but slightly awkward spoken aloud.
- "Some free parking on the left" — grammatically fine but "some" is more ambiguous (how much?).
- "Possibly free on the left — check signs" — the word "possibly" introduces doubt about WePark's data quality, not about the block's partial nature.

**"Sections" is the recommended choice** because it implies a defined subsection of the block (accurate — the tile data has discreet segment zones) and is unambiguous when spoken at driving speed.

The card chip text for the `.free` case is: **"Free — check signs"** (fits the chip width; the voice line has the full "sections" qualifier but the card is a glance-readable label).

### 4.3 Destination mode voice

Kevin's direction was not limited to Cruise Mode. `DrivingContextService.buildUtteranceText` currently produces the zone-by-zone format ("Left side, free until Thu 9:30am. Right side, no parking."). It is replaced with the same catch-all template. The detail ("until Thu 9:30am") is still shown on the card chips; voice in both modes is now the action cue only.

**Destination mode voice change:** `buildUtteranceText` adopts the same template as `CruiseVoicePolicy.utteranceText`. The methods may share a helper or be kept separate (engineer's choice), but the output strings must match the §4.1 table.

**One meaningful difference retained:** in destination mode, the all-restricted-block case is NOT currently gated (destination mode announces every block change). After this spec, the voice in destination mode will still announce on all-restricted blocks, but the phrasing changes to: `"[StreetName]. No parking on either side."` — this keeps the driver informed while staying short. This is a deliberate choice to not silently suppress voice in destination mode (where the context is navigation, not searching).

**Destination mode all-restricted phrasing:**
```
"[StreetName]. No parking on either side."
```
If only one side is restricted (the other is unknown): no voice (same as Cruise Mode). If both are restricted: the above.

### 4.4 Abbreviation expansion

No change to `expandAbbreviations`. The existing regex-based expansion in both `DrivingContextService` and `CruiseVoicePolicy` handles St → Street, Ave → Avenue, etc. The new copy strings use `[StreetName]` as a placeholder for the already-expanded street name.

---

## §5 — "Park Here" Button and Sign-Check Sheet

### 5.1 "Park here" button placement

**Location:** Inside `driveModeOverlayLayer` in `ContentView.swift`, in the existing HStack alongside the "End Cruise"/"End Drive" pill, the mute toggle (Cruise Mode only), and the in-drive Report button.

**Condition:** Visible whenever `driveModeActive == true` (both `.destination` and `.cruise` modes). The arrival prompt (W8.5d) already covers the destination-mode "stopped near destination" case; this button covers the cruise-mode "stopped anywhere" case and supplements destination mode.

**Label:** "Park here" (primary text) with `mappin.and.ellipse` SF Symbol leading icon. Styled as a filled-background capsule button (consistent with "End Drive" pill styling — `.regularMaterial` background). Text color: `.accentColor`.

**Entry guard:** `guard let loc = locationService.userLocation else { return }` — same pattern as the in-drive Report button. If GPS is unavailable, the button is a no-op.

**On tap:**
1. Build `PinDropIntent` from `loc` — same haversine candidate search as the long-press path in `handleLongPress(at:)` (`findCandidateSegments(lat:lng:radius:max:)`).
2. Set `activeSheet = .signCheckConfirm(intent: intent)`.

**Note on interaction with the arrival prompt:** In destination mode, if `activeSheet == .arrivalPrompt(coord:)` is already presented when the driver taps "Park here" in the overlay, the tap is a no-op (the `activeSheet` is non-nil). This is correct — the arrival prompt already contains a "Park Here" button that does the same thing. The overlay button is an independent entry point for cases where the driver missed or dismissed the arrival prompt.

### 5.2 `SignCheckConfirmView` — new sheet

**File:** `ios/WePark/WePark/Views/SignCheckConfirmView.swift`

**Presentation:** `.sheet` via `ActiveSheet.signCheckConfirm(intent:)`, detent `.medium`. `interactiveDismissDisabled(false)` — the user CAN swipe to dismiss (unlike `ParkConfirmView`). Swipe-to-dismiss is equivalent to "Cancel" — does not proceed to pin drop.

**Sheet title:** "Check before you park"

**Subtitle:** "Take 10 seconds — the signs are the final word."

**Checklist (5 items, in this order):**

| # | Icon | Text |
|---|---|---|
| 1 | `signpost.right.fill` | "Read all posted signs on this side of the street — they stack top to bottom, all rules apply." |
| 2 | `flame.fill` | "15 feet from a fire hydrant — no parking (NYC rule; hydrants are easy to miss at night)." |
| 3 | `curbcut.fill` (or `accessibility` SF Symbol if unavailable) | "Not blocking a driveway or curb cut." |
| 4 | `bus.fill` | "Not in a bus stop or no-standing zone (usually marked with a yellow curb or sign)." |
| 5 | `calendar.badge.clock` | "Check today's ASP status — the banner at the top of the map shows it." |

Each item is a toggleable checkbox row (`Toggle` or a custom checkmark row). The checkboxes are OPTIONAL — the user does not need to check all boxes to enable the "Confirm" button. They are educational affordances, not a mandatory gating mechanism. Rationale: mandatory checking would be trivially tapped through without reading, while optional checking preserves the intent-signal without creating friction.

**Confirm CTA:** "I checked — Park here" (`borderedProminent` button style, full width, `.accentColor`). Tapping it dismisses `SignCheckConfirmView` and opens `ActiveSheet.parkConfirm(intent)` — the existing `ParkConfirmView`. See §5.3.

**Cancel path:** "Cancel" text button (secondary, beneath the confirm button). Tapping it dismisses the sheet without proceeding.

**Copy consistency with `FAQHelpView`:** The "signs are the final word" language mirrors `FAQHelpView`'s `section3View` text (`"the sign on the street is always the final word"`) and `footerDisclaimer`. The fire-hydrant rule (15 feet) is consistent with NYC DOT rules referenced in the FAQ. `@ios-engineer` should not paraphrase — use the exact checklist text from this spec.

### 5.3 Where the checklist inserts relative to `ParkConfirmView`

The sign-check sheet is a **pre-step before `ParkConfirmView`**, not inside it. The flow is:

```
[Drive Mode overlay] → tap "Park here"
        ↓
[SignCheckConfirmView sheet]  (ActiveSheet.signCheckConfirm)
    — checklist items —
    [I checked — Park here] button
        ↓
[ParkConfirmView sheet]  (ActiveSheet.parkConfirm)
    — existing: block detection, Wrong street?, safety label, reminder toggle —
    [Park here] button
        ↓
[Pin dropped + ParkUntil sheet fires]  (existing W5/W7.5 flow)
```

**Why before, not inside:** `ParkConfirmView` is also triggered from the long-press path (`handleLongPress`) and the W8.5d arrival prompt confirm path. Inserting the checklist inside `ParkConfirmView` would fire it on ALL three entry paths, including long-press pin drops from users who are browsing the map at home — wrong context. By making `SignCheckConfirmView` a separate sheet triggered only from the "Park here" overlay button, the checklist fires only when the driver has explicitly stopped and tapped the in-drive button.

**`ActiveSheet` change:** Add one new case:
```
case signCheckConfirm(intent: PinDropIntent)
```
`id` value: `"signCheckConfirm-\(intent.id)"`.

The `sheetContent` switch in `ContentView.swift` adds one new arm: `.signCheckConfirm(let intent)` → `SignCheckConfirmView(intent: intent, onConfirm: { confirmedIntent in activeSheet = .parkConfirm(confirmedIntent) }, onCancel: { activeSheet = nil })`.

**`SignCheckConfirmView` inputs:**
- `intent: PinDropIntent` — the in-flight intent, passed through unchanged.
- `onConfirm: (PinDropIntent) -> Void` — called when the user taps "I checked — Park here."
- `onCancel: () -> Void` — called on cancel or swipe-to-dismiss.

`SignCheckConfirmView` does NOT need `ParkingRulesEngine` or `DrivingVoice` — it is static content + a pass-through.

### 5.4 The W8.5d arrival prompt interaction

The W8.5d `ArrivalPromptSheet` ("Park Here" / "Not Yet") already drops a pin at arrival. That flow bypasses `ParkConfirmView` (it calls `parkPinService.save(car)` directly, then fires Park Until). The sign-check sheet does NOT insert into the arrival-prompt path. Rationale: the arrival prompt fires automatically when the driver reaches 50m of their destination — it is time-sensitive. A checklist at that moment is inappropriate friction. The sign-check is only for the explicit in-drive "Park here" button tap.

---

## §6 — Architecture and Files

### 6.1 New files

| File | Owner | Description |
|---|---|---|
| `ios/WePark/WePark/Views/SignCheckConfirmView.swift` | @ios-engineer | Static checklist sheet + pass-through to ParkConfirmView. Pure SwiftUI, no MapKit, no Calendar.current. |
| `ios/WePark/WeParkTests/TF27Tests.swift` | @ios-engineer | Unit tests for the aggregation function + copy strings. See §7. |

### 6.2 Modified files

| File | Change | Risk |
|---|---|---|
| `ios/WePark/WePark/Services/DrivingContextService.swift` | (1) Add `static func aggregateSide(segments:side:engine:date:minimumFreeLength:) -> SideOpportunity`. (2) Update `update(...)` to call `aggregateSide` for left and right cardinal sides in place of single-segment safetyLabel calls. (3) Update `buildUtteranceText` to use the §4.1 copy templates. | Medium — core voice path. Destination-mode regression gate required. |
| `ios/WePark/WePark/Services/CruiseVoicePolicy.swift` | Update `utteranceText(for:)` to use the §4.1 copy templates ("Free parking sections on the [side] — check signs."). The `shouldAnnounce` function and `minimumGapSeconds` constant are unchanged. | Low — text change only to an already-tested function. |
| `ios/WePark/WePark/ContentView.swift` | (1) Add `ActiveSheet.signCheckConfirm(intent: PinDropIntent)` case + `id` value. (2) Add arm to `sheetContent(_:)` switch. (3) Add "Park here" button to `driveModeOverlayLayer`. | Medium — touches `ContentView` and `ActiveSheet`. Live-UI smoke mandatory. |

**Do NOT touch:** `MapViewRepresentable.swift`, `ArrivalPromptSheet.swift`, `ParkConfirmView.swift` (the view itself is not modified — it is still presented as the second step), `ParkUntilSheet.swift`, `FinalApproachService.swift`, `project.pbxproj`, `Info.plist`, `Config.xcconfig*`.

### 6.3 `SideOpportunity` placement

`SideOpportunity` is a value type used only by `DrivingContextService`. Define it at file scope in `DrivingContextService.swift` (like `DrivingContext` is today). Do not make it a new standalone model file — it is an implementation detail of the aggregation function, not a domain model.

### 6.4 Mandatory live-UI smoke gate

`ContentView.swift` is modified. Per the hard gate established after the W8.5c-polish #31 revert: before the PR is merged, the engineer AND QA must each take a simulator screenshot confirming the full overlay chain is intact:
- Gear, find-me, find-my-car, clock, Drive entry button — all visible in resting state.
- ASP banner present if applicable.
- Drive Mode: "End Cruise"/"End Drive" pill, mute toggle (cruise), Report button, NEW "Park here" button — all visible.
- Park Until pill visible if filter is active.
- Drive Mode bottom card chips rendering.

Kevin's manual smoke must confirm: (a) "Park here" button appears while driving; (b) tap opens `SignCheckConfirmView` with all 5 items; (c) "I checked — Park here" opens `ParkConfirmView`; (d) the confirm flow completes to a dropped pin + Park Until sheet.

---

## §7 — Tests

**Baseline:** 479 functions (grep count on `WeParkTests/` as of 2026-06-11).
**Target:** ~494/0 (+15 new tests, 0 failures).

### `TF27Tests.swift` — target: 12 new unit tests

**Aggregation function — `aggregateSide` decision table:**

```
testAggregateSide_singleFreeSegmentLong_returnsFree
    // 1 segment, safetyLabel.severity == .free, length == 10m → .free

testAggregateSide_singleFreeSegmentTooShort_returnsRestricted
    // 1 segment, .free, length == 4m (< 6m minimum) → .restricted (not actionable)

testAggregateSide_mixedFreeAndRestricted_withLongFree_returnsFree
    // 2 segments: seg1 .restricted 30m, seg2 .free 8m → .free (short-circuit on qualifying free)

testAggregateSide_meteredOnly_returnsMetered
    // 1 segment, .metered → .metered

testAggregateSide_allRestricted_returnsRestricted
    // 2 segments, both .restricted → .restricted

testAggregateSide_noSegments_returnsUnknown
    // empty segments array → .unknown

testAggregateSide_freeBeforeMetered_returnsFree
    // seg1 .free 10m, seg2 .metered → .free (free takes priority over metered)

testAggregateSide_minimumFreeLength_boundary_6m_returnsFree
    // segment length exactly == 6.0m and .free → .free (inclusive boundary)

testAggregateSide_minimumFreeLength_boundary_5_99m_returnsRestricted
    // segment length 5.99m and .free → not classified as qualifying free → falls through
    // (if no other free segment, returns .restricted; metered if a metered seg exists)
```

**Copy string smoke tests (for `CruiseVoicePolicy.utteranceText` and `buildUtteranceText`):**

```
testCruiseVoicePhrasing_freeLeft_containsSections
    // aggregateSide returns .free on left → utteranceText contains "sections on the left"
    // and "check signs"

testCruiseVoicePhrasing_meteredRight_noSectionsNoCheckSigns
    // aggregateSide returns .metered on right → utteranceText is "Metered on the right."
    // Does NOT contain "sections" or "check signs"

testBuildUtteranceText_bothRestricted_destinationMode_saysNoParkingEitherSide
    // destination mode, both sides .restricted → contains "No parking on either side."
```

**Note on test fixtures:** `aggregateSide` depends on `ParkingRulesEngine.safetyLabel`. Tests should inject a `MockParkingRulesEngine` or use real test segments (the existing `ParkingRulesEngineParityTests.swift` pattern uses real rule data). The cleanest approach is a minimal `Segment` with one rule that produces a known `SafetyLabel.severity` at a known test date — same pattern used throughout `ParkingRulesEngineParityTests`.

Segment length is computed by `haversineMeters` inside `aggregateSide`. For test fixtures, supply two coordinates that are a known distance apart (use the existing haversine helper — it is already in `DrivingContextService` as a `private` method; extract it to `internal` or `static` so tests can call it, or inline the calculation in the test fixture factory).

### `CruiseVoicePolicyTests.swift` additions — target: 3 new tests

```
testUtteranceText_freeLeft_containsSectionsAndCheckSigns
    // verify the new copy template
testUtteranceText_freeRight_containsSectionsAndCheckSigns
    // verify symmetric case
testUtteranceText_freeBothSides_containsSectionsAndCheckSigns
    // verify both-sides case
```

**All 11 existing `CruiseVoicePolicyTests` continue to pass** — the `shouldAnnounce` decision table is unchanged. The 3 new tests replace the old phrasing assertions (the old tests will fail with the new copy; update them rather than deleting them — keep the test count up by renaming rather than removing).

**Architecture invariants (QA will verify):**
- No `Calendar.current` in any new or modified service file.
- No `import SwiftUI` in `DrivingContextService.swift` or `CruiseVoicePolicy.swift`.
- `aggregateSide` has no `@Observable` or `@MainActor` annotation — it is a pure static function.
- `SignCheckConfirmView.swift` does NOT import MapKit or CoreLocation (it is static content).

---

## §8 — Work Streams

Single PR — all files are owned by `@ios-engineer`. The aggregation function, voice copy, button, and sheet are tightly coupled: shipping the voice change without the aggregation function would break the copy (the existing single-segment label text does not match the "sections" template). Shipping the button without the sheet has no value.

| Stream | Owner | Serializes after | Estimate |
|---|---|---|---|
| **TF2-7.A** — `SideOpportunity` + `aggregateSide` + `TF27Tests.swift` (aggregation tests) | @ios-engineer | Nothing (pure new logic, no existing code dependency beyond `ParkingRulesEngine`) | 0.5 sessions |
| **TF2-7.B** — `DrivingContextService` + `CruiseVoicePolicy` copy update | @ios-engineer | TF2-7.A (uses `aggregateSide` output) | 0.5 sessions |
| **TF2-7.C** — `SignCheckConfirmView` + `ActiveSheet` case + `ContentView` button | @ios-engineer | TF2-7.B (sheet confirm proceeds to `ParkConfirmView`, must not regress voice path tests) | 0.5 sessions |
| **TF2-7.D** — Live-UI smoke + QA pass | @qa-verifier | TF2-7.C merged | 0.5 sessions |

**Total: ~1.5 engineer sessions + 0.5 QA sessions.**

`@designer` input: the "Park here" button placement in the drive overlay and the `SignCheckConfirmView` checklist layout are simple enough to proceed without a design review cycle. However, if Kevin wants a design pass on the checklist layout (icon alignment, checkbox style, button hierarchy), the `@designer` agent can review `SignCheckConfirmView` during TF2-7.D in parallel with the engineer fixing any QA findings.

---

## §9 — Acceptance Criteria

QA verifies all of the following against the merged code.

**Aggregation function:**
- [ ] **TF2-7.1** `aggregateSide` called with segments where at least one side-matching segment has `safetyLabel.severity == .free` and haversine length ≥ 6.0m returns `.free`.
- [ ] **TF2-7.2** `aggregateSide` called with a free segment whose haversine length < 6.0m and no other free segment returns `.restricted` (not `.free`).
- [ ] **TF2-7.3** `aggregateSide` called with mixed free+restricted segments where the free segment is ≥ 6.0m returns `.free`.
- [ ] **TF2-7.4** `aggregateSide` called with no segments for the given side returns `.unknown`.
- [ ] **TF2-7.5** `aggregateSide` called with only metered segments returns `.metered`.

**Voice copy:**
- [ ] **TF2-7.6** When left side aggregates to `.free`, `CruiseVoicePolicy.utteranceText` returns a string containing `"sections on the left"` and `"check signs"`.
- [ ] **TF2-7.7** When right side aggregates to `.free`, `CruiseVoicePolicy.utteranceText` returns a string containing `"sections on the right"` and `"check signs"`.
- [ ] **TF2-7.8** When both sides aggregate to `.free`, `utteranceText` contains `"both sides"` and `"check signs"`.
- [ ] **TF2-7.9** When neither side is `.free` and left is `.metered`, `utteranceText` contains `"Metered on the left."` and does NOT contain `"sections"` or `"check signs"`.
- [ ] **TF2-7.10** `DrivingContextService.buildUtteranceText` (destination mode) produces the same catch-all templates as `CruiseVoicePolicy.utteranceText` for equivalent `SafetyLabel` inputs — a free side produces "sections...check signs", a metered-only side produces "Metered on the [side]."
- [ ] **TF2-7.11** Destination mode with both sides `.restricted` produces voice text containing `"No parking on either side."` (destination mode does not silence all-restricted blocks).

**"Park here" button:**
- [ ] **TF2-7.12** A "Park here" button is visible in the Drive Mode overlay whenever `driveModeActive == true` (both `.cruise` and `.destination` modes).
- [ ] **TF2-7.13** Tapping "Park here" while `locationService.userLocation` is nil is a no-op (no crash, no sheet presented).
- [ ] **TF2-7.14** Tapping "Park here" while `activeSheet != nil` is a no-op (guard already present via `sheetContent` mutual exclusivity).

**Sign-check sheet:**
- [ ] **TF2-7.15** `SignCheckConfirmView` presents 5 checklist items matching the §5.2 text exactly (QA verifies by code inspection of the string literals).
- [ ] **TF2-7.16** The sheet title is "Check before you park" and subtitle is "Take 10 seconds — the signs are the final word."
- [ ] **TF2-7.17** Tapping "I checked — Park here" dismisses `SignCheckConfirmView` and opens `ParkConfirmView` with the same `PinDropIntent` (no coordinate mutation).
- [ ] **TF2-7.18** Tapping "Cancel" or swiping down dismisses `SignCheckConfirmView` without presenting `ParkConfirmView`.
- [ ] **TF2-7.19** The W8.5d arrival prompt path (`ActiveSheet.arrivalPrompt`) does NOT present `SignCheckConfirmView` at any point — the sign-check is exclusive to the in-drive "Park here" button entry path.

**Live-UI smoke (mandatory pre-merge gate):**
- [ ] **TF2-7.20** Simulator screenshot in resting mode (Drive Mode inactive): toolbar layer intact — gear, find-me, find-my-car, clock, Drive entry button all visible. No regression of the #31 overlay chain.
- [ ] **TF2-7.21** Simulator screenshot with `driveModeActive == true`: "End Drive" pill, "Park here" button, Report button, mute toggle (in Cruise Mode) all visible. ASP banner present.
- [ ] **TF2-7.22** Kevin's manual smoke confirms: (a) tapping "Park here" in drive overlay opens `SignCheckConfirmView` with all 5 items; (b) "I checked — Park here" transitions to `ParkConfirmView`; (c) completing `ParkConfirmView` drops a pin and fires the Park Until sheet; (d) voice announces "Free parking sections on the left — check signs." when passing a mixed block with a qualifying free stretch.

**Regression:**
- [ ] **TF2-7.23** All existing destination-mode Drive Mode ACs (W8.5c, W8.5d) pass after this PR. `xcodebuild test` exits 0 with at least 494 tests passing (479 baseline + 15 new). No new `Calendar.current`. No `import SwiftUI` in service files.

---

## §10 — Out-of-Scope Follow-Ups

**Minimum free stretch UX disclosure.** The "check signs" qualifier in voice is the honesty signal for partial coverage. A future enhancement could display the approximate free stretch length on the card chip ("~40ft free on left — check signs"), but this requires formatting meters-to-feet for street distances, and the tile segments do not have user-facing length labels today. Deferred — the "sections" qualifier + "check signs" is sufficient for TF2.

**Sign-check analytics.** How often do users tap through the checklist vs. cancel? A lightweight `UserDefaults` counter (how many times `SignCheckConfirmView` confirm was tapped vs. cancel) could inform whether to keep it always-shown or add a dismiss option. Deferred pending TF2 user volume — not worth instrumentation until the app has real users.

**Haptic on free-block detection.** `docs/cruise-mode-spec.md §10` deferred haptic feedback to patrol mode's precedent-setting. Now that patrol mode shipped as universal reporting (not a dedicated mode), the haptic question resurfaces. Recommendation: a `UIImpactFeedbackGenerator.medium` on the first voice announcement per block is a one-line addition, but out of scope for this spec — add to a TF2 polish pass.

**Voice copy for one-way streets.** On a one-way street where only one cardinal side is accessible in the driver's direction of travel, the "left/right" phrasing is correct (the aggregation correctly classifies one side as `.unknown` if there are no segments on that cardinal side). No special one-way copy is needed. However, if drive-test feedback surfaces confusion about left/right on one-way blocks, a "same side as traffic / opposite side" qualifier may be warranted — deferred to a W8.5c-follow calibration pass.

---

*Spec written by @tech-lead 2026-06-11. Engineer: read §3.6 before writing any code — the aggregation integration point in `DrivingContextService.update` is the load-bearing change; all other changes (copy, sheet, button) flow from it. QA: TF2-7.20 and TF2-7.21 (live-UI smoke) are merge-blocking; TF2-7.22 requires Kevin's manual smoke before the PR is closed. Do not self-sign-off. OQ-1 (always-shown vs. dismissible) must be resolved by Kevin before TF2-7.C starts.*
