# Community 1.0 iOS Model Layer QA Pass 1 — 2026-06-02

**Reviewed:** branch `ios/community-pin-model` at `9310240`, against `docs/typed-pin-schema-spec.md §10`
**Verdict:** PASS WITH NITS

---

## Summary

The Community 1.0 iOS model layer (`CommunityPin.swift` + `CommunityPinTests.swift`) is
correctly implemented and faithfully matches the §10 contract. All 10 `PinType` raw values
are exact, all per-type meta structs match the §4.3 field names and types, the snake_case
`CodingKeys` are complete and correct, and the malformed/unknown-type path degrades gracefully
(no crash, returns nil via the soft-failure helper). The build compiles clean and all 280 tests
pass with 0 failures. Three nit-level findings below; none block merge.

---

## No-UI-files confirmation

`git diff main --name-only` shows the following files changed:

```
docs/community-1.0-buildplan.md
docs/community-1.0-direction.md
docs/qa/community-1.0-schema-qa.md
docs/tier1-open-data-ingest-spec.md
docs/typed-pin-schema-spec.md
ios/WePark/WePark/Models/CommunityPin.swift
ios/WePark/WeParkTests/CommunityPinTests.swift
supabase/02-pins-schema.sql
supabase/02b-pins-ingest-indexes.sql
```

**No UI files are present.** `MapViewRepresentable.swift`, `ContentView.swift`, and all
`Views/DriveMode*.swift` files are untouched. The live-UI smoke gate is NOT required for
this PR class per the QA brief.

The diff includes `supabase/` SQL files and `docs/` additions beyond the two iOS files
originally scoped. These are all read-only from the perspective of the iOS model layer and
do not affect this gate. The SQL files are out of scope for this QA pass (schema QA is a
separate gate per §12 / TEAM.md).

---

## Acceptance criteria checklist

- [x] **AC-I1.** `CommunityPin` decodes a fixture JSON row for each of the 10 pin types
  without error. Verified: 10 fixture-decode tests pass (`testDecode_filming` through
  `testDecode_parkedCar`).

- [x] **AC-I2.** `PinMeta` for `enforcement_active` with `sub_tag: null` decodes to
  `.enforcementActive(EnforcementActiveMeta(subTag: nil))`. Verified:
  `testDecode_enforcementActive_subTagNull` + `testDecode_enforcementActive_subTagNullExplicit`
  both pass. Implementation uses `decodeIfPresent` for `subTag`.

- [x] **AC-I3.** `PinMeta` for `enforcement_active` with `sub_tag: "cleaning_truck"` decodes
  to `.enforcementActive(EnforcementActiveMeta(subTag: .cleaningTruck))`. Verified:
  `testDecode_enforcementActive_subTagCleaningTruck` passes.

- [x] **AC-I4.** `CommunityPin` with `expires_at: null` decodes `expiresAt` as `nil` (not
  crash). Verified: `testDecode_expiresAt_null_isNil` passes. Implementation uses
  `decodeIfPresent`.

- [x] **AC-I5.** `CommunityPin` with `resolved_at` set decodes `resolvedAt` as a non-nil
  `Date`. Verified: `testDecode_resolvedAt_set_isNonNil` passes.

- [x] **AC-I6.** No `Calendar.current` usage in `Models/CommunityPin.swift` or any meta
  struct. Verified: `grep "Calendar.current" CommunityPin.swift` returns only comment
  lines. The test file also uses only hardcoded ISO 8601 string constants for dates.

- [x] **AC-I7.** `PinType.rawValue` for each case matches the SQL enum string exactly.
  Verified: 10 `testRawValue_*` tests pass, plus `testPinType_exactlyTenCases` asserts
  `PinType.allCases.count == 10`.

---

## Findings

### Blocking

None.

### Significant

None.

### Minor / nit

**Nit #1: `testGracefulDecode_unknownPinType_returnsNil` does not call `gracefulDecode(from:)`**

- Where: `CommunityPinTests.swift:516–528`, `CommunityPin.swift:204–211`
- What: The test named `testGracefulDecode_unknownPinType_returnsNil` is described in its
  doc comment as testing `CommunityPin.gracefulDecode` but the implementation manually
  wraps `decoder.decode(CommunityPin.self, ...)` in a do/catch instead of calling
  `CommunityPin.gracefulDecode(from: decoder)`. The `gracefulDecode` method itself is
  never directly invoked in any test. The method's behavior is correct and tested by
  proxy (the try/catch produces identical observable behavior), but a future change to
  `gracefulDecode` — say, adding logging or changing its catch scope — would not be
  caught by this test.
- Expected: The test should obtain a `Decoder` instance and pass it to
  `CommunityPin.gracefulDecode(from:)` directly.
- Repro: Inspect `testGracefulDecode_unknownPinType_returnsNil` — no call to
  `CommunityPin.gracefulDecode(from:)` exists anywhere in `WeParkTests/`.
- Owner: `@ios-engineer`

**Nit #2: Test file header inventory count is wrong (30 vs 37 actual)**

- Where: `CommunityPinTests.swift:64` — `// Baseline: 243/0. After Community 1.0 model layer: 243 + 30 = 273/0 (target).`
- What: The header inventory lists 30 numbered tests and claims "243 + 30 = 273/0 (target)",
  but `grep -c "func test"` returns 37. The 7 extra tests are real, non-trivial tests
  (5 additional `EnforcementSubTagTests` variants + 2 additional `CommunityPinTemporalTests`
  + 1 additional malformed-JSON test) that were added without updating the inventory
  comment. The PR description correctly claims "280/0" (243 + 37), but the file header
  is stale. This is the same off-by-one documentation pattern flagged in W8.5d QA.
- Expected: Header comment should read "243 + 37 = 280/0 (total)" and the inventory
  should list all 37 tests.
- Owner: `@ios-engineer`

**Nit #3: PR diff scope includes `supabase/` SQL files not declared in the scope statement**

- Where: `supabase/02-pins-schema.sql`, `supabase/02b-pins-ingest-indexes.sql`
- What: The PR branch carries two Supabase SQL files that are out of scope for the iOS
  model layer review. These files have not been QA'd against the schema acceptance
  criteria (AC-S1 through AC-S12) in this pass — that is a separate `@backend-data` +
  `@qa-verifier` gate per §12. A reviewer scanning this PR for iOS-only changes could
  miss the SQL content entirely or assume it was already gated. The SQL files look
  structurally correct at a glance, but they have not been run against a live Supabase
  project in this review.
- Expected: The SQL schema gate (AC-S1–S12, specifically the RLS tests AC-S5 through
  AC-S8 and the trigger test AC-S9) should be completed as a separate QA pass before
  the schema is applied to production. This is already noted as a separate stream
  (Stream A) in §12, but the files being on the iOS PR branch conflates the two gates.
- Owner: `@ios-engineer` / `@backend-data` to acknowledge; `@qa-verifier` to run
  the schema pass separately.

### Out of scope (logged, not fixed)

- The `supabase/02-pins-schema.sql` and `supabase/02b-pins-ingest-indexes.sql` files
  are on this branch but their AC-S1–S12 acceptance criteria are out of scope for this
  iOS model-layer QA pass. They should be gated separately before production apply.

---

## Smoke tests run

1. **Branch checkout + diff scope check.** Confirmed `git diff main --name-only`. No UI
   files (`MapViewRepresentable.swift`, `ContentView.swift`, `Views/DriveMode*.swift`)
   are present. Live-UI smoke gate not required.

2. **Token scan.** `grep -r "pk.eyJ" ios/` returns one hit: `ios/WePark/Config.xcconfig`
   (gitignored, pre-existing, not introduced by this PR). The PR diff itself contains
   zero Mapbox token strings.

3. **`Calendar.current` scan.** `grep "Calendar.current" CommunityPin.swift` returns only
   comment lines (not code). AC-I6 passes.

4. **Build.** `xcodebuild build-for-testing` completed with exit code 0. No compile
   errors, no warnings surfaced in the scan.

5. **Test run.** `xcodebuild test-without-building` on
   `platform=iOS Simulator,id=F0820726-15F4-4FA3-8602-A5D7B479A277` (iPhone 17 Pro,
   iOS 26.4). Result: **280 passed / 0 failed**. Verified by counting
   `"passed on 'Clone"` lines (280) and `"failed on 'Clone"` lines (0).

6. **Test function count.** `grep -c "func test" CommunityPinTests.swift` = 37.
   PR description claims 37 new tests. Confirmed.

7. **Assertion spot-check (not empty stubs).** Reviewed `testDecode_filming`,
   `testDecode_signCorrection`, `testDecode_parkedCar`, and
   `testDecode_enforcementActive_subTagCleaningTruck` in detail. All assert specific
   decoded field values (e.g., `m.permitId == "NYC-2026-001"`,
   `m.segmentId == "7th Ave|W 32nd St|W 33rd St"`, `m.subTag == .cleaningTruck`).
   No empty or trivially-passing stubs found.

8. **Contract fidelity — PinType enum.** Verified all 10 raw values against §10.1:
   `filming`, `asp_suspended_today`, `special_event`, `construction`, `sign_correction`,
   `block_note`, `enforcement_active`, `sweeper_passed`, `broken_meter`, `parked_car`.
   All match exactly. `testPinType_exactlyTenCases` asserts the count is 10.

9. **Contract fidelity — CodingKeys.** Verified all snake_case mappings in
   `CommunityPin.CodingKeys` against §10.3. All 17 fields present and correctly mapped.
   `authorUsername = "author_username"` correctly maps to the `pins_with_author` view
   column.

10. **Contract fidelity — per-type meta structs.** Cross-checked all 10 meta structs
    against §4.3:
    - `FilmingMeta`: `permit_id` (required String), `production_name?`, `film_office_url?` — correct.
    - `ASPSuspendedMeta`: `suspension_date` (required String), `reason?` — correct.
    - `SpecialEventMeta`: `event_name`, `event_type` (enum: parade/marathon/snow_emergency/fair/other) — correct.
    - `ConstructionMeta`: all 4 fields optional (`permit_id?`, `agency?`, `start_date?`, `end_date?`) — correct.
    - `SignCorrectionMeta`: `segment_id` (required), `reported_issue` (required), `existing_rule_text?` — correct.
    - `BlockNoteMeta`: `category` (enum: safety/flooding/parking_norm/other), `headline` — correct. Note: no explicit `CodingKeys`; auto-synthesis maps `category` → `"category"` and `headline` → `"headline"` which matches the spec JSON keys.
    - `EnforcementActiveMeta`: `sub_tag?` (enum: parking_agent/cleaning_truck/tow_truck) — correct.
    - `SweeperPassedMeta`: `direction?` (enum: passed/coming_soon) — correct.
    - `BrokenMeterMeta`: `meter_id?` — correct.
    - `ParkedCarMeta`: 5 optional W5-mirror fields, all snake_case CodingKeys — correct.

11. **Malformed/unknown-type graceful degradation.** Reviewed `PinMeta.decode(pinType:from:)` —
    it is called from `CommunityPin.init(from:)` which throws on unknown `pin_type` (correct;
    `PinType.init(rawValue:)` returns nil and JSONDecoder surfaces a `DecodingError`).
    `gracefulDecode(from:)` catches and returns nil. `testDecode_unknownPinType_throwsDecodingError`
    and `testDecode_malformedJSON_missingId_throws` both pass. No crash path found.

12. **No force-unwraps.** `grep "!" CommunityPin.swift` filtered to non-comment, non-`!=`
    lines returns no hits. Confirmed.

---

## What's working

- Complete implementation of all §10 types in a single well-structured file with clear
  MARK sections and doc comments referencing the spec section numbers.
- The `PinMeta.decode(pinType:from:)` dispatch strategy is sound: reads `pin_type` once
  from the parent container, dispatches to the correct struct decoder, avoids any
  runtime type-switching or reflection hacks.
- The `gracefulDecode` soft-failure helper is a good defensive pattern for list-decoding
  scenarios where a single bad row should not crash the feed.
- The decoder is configured with a dual-pass ISO 8601 formatter (fractional seconds then
  plain) matching real Supabase `timestamptz` format — this is the correct production
  choice and avoids the common JSONDecoder `.iso8601` mistake that fails on
  `timestamptz` strings with fractional seconds.
- `@MainActor` annotations on test classes are correct and well-documented — this
  addresses the same isolation issue fixed in PR #8ad84e4.
- 37 new tests cover all 7 spec acceptance criteria (AC-I1 through AC-I7) with real
  assertions, plus defensive edge cases (absent `sub_tag` key, malformed JSON, empty
  construction meta object).
- No `Calendar.current`, no SwiftUI import, no Supabase client import, no force-unwraps —
  all four documented invariants hold.
