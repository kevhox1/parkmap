# FT-15/TF2-15 Stream B2 — Map Tap-Select + Report Sheet QA Pass 1 — 2026-08-18

**Reviewed:** branch `ios/ft15-b2-tap-select-report-sheet` at `9a522a48` (PR #82), against
`docs/ft15-tf215-temporary-block-restrictions-spec.md`. Cross-checked against branch
`ios/ft15-b3-write-path-evidence-upload` at `171dd0fe` (PR #81, the interface B2 depends on but
which is not yet on `main`).

**Verdict:** 🟡 ship with caveats — pending the mandatory Mac gates below. Code review finds no
blocking defect in B2 itself, no interface mismatch against B3, and no PII/live-schema violation.
One real, previously-unflagged interaction gap (block-select mode is not actually mutually
exclusive with entering Drive Mode, despite the code's own comment claiming it is) should be fixed
before or shortly after merge — it is not a crash risk but it does undermine the FT-17a/FT-18
Bottom Dock chrome Kevin just spent a session validating on-device.

This PR **cannot be built or tested at all** on this VPS (no Xcode/Swift toolchain) and, as the
author's own PR description states, **cannot even compile standalone** — it references four
symbols (`insertBlockScopedReport`, `BlockScopedReportSelection`, `BlockScopedReportError`,
`resolvedExpiresAt`/`hardCeiling`) that exist only on PR #81's branch, not yet on `main`. My job on
this pass was (1) verify by hand that the B2↔B3 interface actually lines up so a Mac round trip
isn't wasted on a mismatch, and (2) do the deepest cold read of B2's own logic that's possible
without a compiler. Both are done below.

## B2 ↔ B3 interface check — no mismatch found

I fetched B3 (`171dd0fe`) and pinned it to a local ref, then compared every call site in B2 against
B3's actual declarations line-by-line (not just the doc comments):

| B2 call site | B3 declaration | Match |
|---|---|---|
| `pinService.insertBlockScopedReport(pinType:selections:startsAt:expiresAt:notes:evidencePhoto:)` (`BlockRestrictionReportSheet.swift:~430`) | `func insertBlockScopedReport(pinType: PinType, selections: [BlockScopedReportSelection], startsAt: Date, expiresAt: Date?, notes: String?, evidencePhoto: Data, evidenceContentType: String = "image/jpeg") async throws -> BlockScopedReportResult` | ✅ every label, type, and optionality matches; B2 omits `evidenceContentType` and takes the default, which is legal |
| `BlockScopedReportSelection(blockfaceKey:lat:lng:)` | `struct BlockScopedReportSelection { let blockfaceKey: String; let lat: Double; let lng: Double; init(blockfaceKey: String, lat: Double, lng: Double) }` | ✅ |
| `CommunityPinService.resolvedExpiresAt(pinType:startsAt:requested:)` (static, used twice — once for the submit call, once for the "we'll assume X" hint text) | `nonisolated static func resolvedExpiresAt(pinType: PinType, startsAt: Date, requested: Date?) -> Date` | ✅ — and B2 correctly calls the *same* function for both the displayed hint and the actual submitted value (AC-R6), so they structurally cannot drift |
| `CommunityPinService.hardCeiling(for:)` | `nonisolated static func hardCeiling(for pinType: PinType) -> TimeInterval?` | ✅ |
| `(error as? LocalizedError)?.errorDescription` on the thrown error | `extension BlockScopedReportError: LocalizedError` with 8 non-generic, non-PII-leaking cases including a distinct `.rateLimitExceeded` message | ✅ — B2 never pattern-matches on individual `BlockScopedReportError` cases, so it's decoupled from B3's exact case list; any future case B3 adds still surfaces correctly |

No file-level conflict either: B2 touches `ContentView.swift`, `MapViewRepresentable.swift`,
`Views/BlockRestrictionReportSheet.swift` (new), `project.pbxproj`, `WeParkTests/FT15B2Tests.swift`
(new). B3 touches `Services/CommunityPinService.swift`, `Services/PinEvidenceUploader.swift` (new),
`WeParkTests/FT15B3Tests.swift` (new). Zero file overlap — merging #81 then rebasing #82 onto it
should be a clean, non-conflicting rebase.

**This is genuinely the cleanest B-stream interface I've checked in this feature's QA history** —
every parameter label, type, and optionality lines up exactly, and the error-handling code is
decoupled from B3's specific enum cases rather than pattern-matching them. I could not find the
mismatch the task briefed me to hunt for. That said, this is a hand-check, not a compiler — actor
isolation subtleties (`CommunityPinService` is `@MainActor`; `insertBlockScopedReport` is called
with `await` from inside a `Task { }` in a SwiftUI view's private method) *should* be fine per
normal Swift concurrency rules (cross-actor async calls always hop correctly), but "should be fine"
is exactly the sentence a Mac compile exists to confirm, not replace.

## 🔴-priority item — Info.plist camera-permission bridge

**Verdict: the pattern used here is very likely correct, and is not the same bug class as
W8.5a — but this absolutely still needs the PlistBuddy gate given the stakes.**

The diff adds exactly this, to both Debug and Release:
```
INFOPLIST_KEY_NSCameraUsageDescription = "WePark uses your camera to photograph posted signs...";
INFOPLIST_KEY_NSPhotoLibraryUsageDescription = "WePark falls back to your photo library...";
```

The W8.5a bug (HANDOFF.md) was that `INFOPLIST_KEY_MAPBOX_ACCESS_TOKEN` — a **custom, non-Apple**
key — was silently dropped by Xcode's `INFOPLIST_KEY_*` → generated-Info.plist mechanism, and the
fix was a physical `Info.plist` stub with `$(MAPBOX_ACCESS_TOKEN)` substitution, merged in via
`INFOPLIST_FILE = Info.plist` alongside `GENERATE_INFOPLIST_FILE = YES`.

Three things distinguish this PR's case, and I checked all three directly rather than assuming:

1. **`NSCameraUsageDescription`/`NSPhotoLibraryUsageDescription` are Apple-recognized privacy-usage
   keys**, not custom keys like `MAPBOX_ACCESS_TOKEN` was. Xcode's newer build system has native
   `INFOPLIST_KEY_<AppleKey>` support for exactly this category of key (it's literally what backs
   the "Privacy - Camera Usage Description" field in Xcode's Info tab UI) — this is architecturally
   different from the custom-key case that broke.
2. **This repo already has a working, in-production precedent for this exact pattern.**
   `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` has been set the identical way (pbxproj-only,
   no entry in the physical `Info.plist` stub) since before this PR, and it demonstrably works today
   — Kevin's location-permission prompt has been live and functioning since well before this build
   (Drive Mode, "Find me," etc. all depend on it). I read the physical stub directly
   (`ios/WePark/Info.plist`) and confirmed it contains only `MAPBOX_ACCESS_TOKEN`,
   `SUPABASE_ANON_KEY`, `SUPABASE_URL` — **no** `NSLocationWhenInUseUsageDescription` entry, no
   `NSCameraUsageDescription`, no `NSPhotoLibraryUsageDescription`. So the working location-key
   precedent and this PR's two new keys use the exact same mechanism (`INFOPLIST_KEY_*` only, no
   physical-stub entry), which is direct in-repo evidence this class of key merges correctly even
   with `INFOPLIST_FILE` also set.
3. **Both Debug and Release configs got the addition** (confirmed in the diff — 2 lines × 2
   configs), and there's no duplicate/colliding key definition anywhere else in `project.pbxproj`.

Given (1)+(2)+(3), my assessment is this will land in the built bundle correctly. **But the
task brief's framing is right that the stakes here are categorically worse than W8.5a's** — a
missing `NSCameraUsageDescription` doesn't degrade a feature (silent `nil` token), it makes iOS
**hard-kill the app the instant `UIImagePickerController` with `.sourceType = .camera` is
presented**. A "very likely correct" conclusion is not an acceptable bar for a crash-on-first-tap
risk.

**Mandatory Mac gate, regardless of the above:**
```
xcodebuild -project ios/WePark/WePark.xcodeproj -scheme WePark -configuration Debug build \
  -derivedDataPath /tmp/wepark-build
PlistBuddy -c "Print :NSCameraUsageDescription" /tmp/wepark-build/Build/Products/Debug-iphonesimulator/WePark.app/Info.plist
PlistBuddy -c "Print :NSPhotoLibraryUsageDescription" /tmp/wepark-build/Build/Products/Debug-iphonesimulator/WePark.app/Info.plist
```
Both must print the actual copy strings, not "Entry does not exist." Do this before the live-UI
smoke below — if it fails, tapping "Take Photo" in the simulator smoke will kill the app instantly
and waste the rest of the smoke pass.

## Core design integrity — verified intact

`Segment.blockfaceKey` (already on `main` via B1, unmodified by B2) is exactly the pure,
verbatim, string-equality-only key the spec §4.3 specifies:
```swift
var blockfaceKey: String {
    let (lo, hi) = fromStreet <= to ? (fromStreet, to) : (to, fromStreet)
    return "\(street)|\(lo)|\(hi)|\(side)"
}
```
No `.uppercased()`, no trimming, no fuzzy matching — confirmed by reading the whole property and
its doc comment, which explicitly calls out that it does *not* normalize casing itself (it's
uppercase only because the tile pipeline guarantees uppercase source data).

`ContentView.toggledBlockSelection(current:tappedKey:bothCurbsOn:oppositeKey:)` and
`ContentView.oppositeSideSegment(of:in:)` (both new, `static`, in `BlockRestrictionReportSheet`'s
sibling file `ContentView.swift`) are both pure — no `MapViewRepresentable`/SwiftUI dependency,
no string manipulation of any kind beyond `Set` membership and an unordered from/to comparison.
`oppositeSideSegment` matches on `candidate.side != segment.side && candidate.street ==
segment.street && Set([candidate.fromStreet, candidate.to]) == Set([segment.fromStreet,
segment.to])` — key-based, no normalization. 20 unit tests exercise both functions directly,
including the "no opposite side loaded → 1-block selection, no crash" case (AC-R2) and the
"deselect doesn't remove the opposite curb" case.

**Kevin's canonical case (2 blocks × 2 curbs = 4 blockfaces, E 2nd St, 3rd Ave→1st Ave):** covered
on the B2 side by `testSummary_twoBlocksBothCurbs_fourBlockfaces_kevinsCanonicalCase` (asserts the
sheet's summary text reports "4 blockfaces" + "both curbs" for exactly this fixture), and covered
end-to-end at the write-path layer on B3's side by
`testInsertBlockScopedReport_fourRowBatch_allShareOneReportGroupId` +
`testInsertBlockScopedReport_eachRowCarriesItsOwnSegmentId` (4 rows, one shared `report_group_id`,
each row's `segment_id` equal to its own `blockfaceKey`). The two pure toggle/opposite-side
functions that would actually *build* that 4-key selection from two taps are tested individually
but not chained together in one canonical-case integration test on the B2 side — a reasonable gap
given pure-function unit tests are the only thing runnable pre-Mac, but worth naming as one more
thing the live-UI smoke should specifically exercise (the PR's own smoke checklist already does:
"Tap one blockface... confirm the bar reads '1 block selected (2 blockfaces)'... Tap the adjacent
block... confirm '2 blocks selected (4 blockfaces)'").

**Display-only summary text does not leak into submission — verified, not assumed.**
`selectionSummary(for:)`'s 3+-cross-street comma-list fallback (the deviation the author flagged)
only feeds `Text(summaryText)` in the sheet's UI. I traced `submit()` directly: it builds
`blockScopedSelections` from `selections.compactMap { segment in ... BlockScopedReportSelection(
blockfaceKey: segment.blockfaceKey, ...) }` — reading straight off the `[Segment]` array passed
into the sheet, with zero reference to `summaryText`/`selectionSummary` anywhere in the submit path.
The fallback is a legitimate, spec-consistent scope cut (§4.1 explicitly names the general
street-topology-ordering problem as out of scope) and does not affect what's actually written to
the database. Acceptable as shipped.

## MapViewRepresentable.swift — additive-only, confirmed

- New `OverlayTag.blockSelectHighlight` case (7th), new `blockSelectKeys: Set<String>` input, new
  `Coordinator.syncBlockSelectHighlight(_:segments:on:)`, new dashed `.systemPurple` renderer case
  in the exhaustive `mapView(_:rendererFor:)` switch. All additive; nothing in the existing 5-state
  + `selectedBlock` + `routePolyline` overlay machinery is touched or renamed.
- `syncBlockSelectHighlight` is called from `updateUIView` and does **only** `removeOverlay` /
  `addOverlay` — I read the full function body and there is no `setCamera`, `setRegion`, or any
  camera-state read/write anywhere in it. Same shape as the existing `syncCommunityPinAnnotations`
  precedent this PR explicitly modeled itself on.
- Cheap equality gate (`lastAppliedBlockSelectKeys != keys`) avoids rebuilding the overlay on every
  60s tick when the selection hasn't changed — consistent with the file's existing generation-gate
  pattern elsewhere.
- Z-order: `applyOverlayPayload`'s existing S-1-pattern re-insertion loop was extended to also
  re-insert `blockSelectOverlay` above the freshly-rebuilt parking-state overlays after every
  60s/selection-triggered rebuild — correctly reasoned, since `applyOverlayPayload` can fire while
  block-select mode is simultaneously active.
- **No `region` write in `updateUIView`** anywhere in this diff — confirmed by reading the full
  diff hunk, not just grepping for the string. The #31 invariant (camera mutation only via the
  `.onChange`-driven `CoordinatorActions` closure pattern, never inside `updateUIView`) holds.

This is a clean, minimal, correctly-scoped touch to the single most regression-sensitive file in
the project. No concerns here beyond the standard mandatory live-UI smoke this file class always
requires.

## 🟡 Significant finding — block-select mode is not actually exclusive with Drive Mode entry

The PR's own doc comment claims: *"Mutually exclusive with Drive Mode by construction — the
confirmationDialog that sets this to `true` only ever presents when `driveModeActive == false`
..., so this flag and `driveModeActive` are never both `true` at once."* That covers **entering**
block-select mode while driving (correctly guarded, verified — `handleLongPress`'s guard is
`guard !driveModeActive, !blockSelectModeActive else { return }`). It does **not** cover the
reverse: nothing stops the user from **entering Drive Mode while already in block-select mode.**

- `recenterButtonStack` (which hosts "Find me," "Find my car," the Park Until clock button, and
  the `driveEntryButton` Menu with "Drive to a destination" / "Find Parking nearby") is gated in
  `mapZStack` only by `if driveModeActive { endDriveControl } else { recenterButtonStack ... }` —
  **no `blockSelectModeActive` check anywhere in that branch.**
- `enterCruiseMode()` (`driveModeStyle = .cruise; driveModeActive = true`) and the "Drive to a
  destination" path (`showDriveModeDestination = true`, gated only by `activeSheet == nil`, which
  is true during block-select mode since `enterBlockSelectMode()` sets `activeSheet = nil`) do not
  read or reset `blockSelectModeActive` / `selectedBlockKeys` anywhere — I grepped every call site.
- `handleDriveModeChange`/`handleDriveModeAndCamera` (the `.onChange(of: driveModeActive)` chain)
  also never touch block-select state.

**Repro:** long-press → "Report closure (film shoot / construction)" → (without tapping
Cancel/Continue) tap the still-visible Drive entry button in the top-right toolbar → "Find Parking
nearby." Result: `driveModeActive == true` and `blockSelectModeActive == true` simultaneously,
which the code's own comment asserts is impossible.

**Observable consequences from tracing the code (not yet visually confirmed — needs Mac):**
`bottomSafeAreaContent`'s VStack renders `recenterRow`/`driveActionRow` (Drive Mode's Bottom Dock,
FT-18) **and** `blockSelectBar` simultaneously — two competing action rows stacked, undermining the
exact chrome-isolation Kevin approved in FT-18 (`docs/design/ft18-drive-mode-layout.md`'s core
finding was "two anchors" confusion from exactly this class of simultaneous-row bug). Worse:
`handleMapTap` checks `blockSelectModeActive` **first**, so any map tap during this dual state
routes into `handleBlockSelectTap` — silently adding/removing blockfaces from an abandoned
selection — instead of whatever tap behavior Drive Mode otherwise has. If the user then taps
Continue on the still-live `blockSelectBar`, `BlockRestrictionReportSheet` presents as a full modal
sheet **on top of active Drive Mode**, pulling attention to a multi-field form (including a camera
capture step) while the app believes the user is actively driving — a real UX/safety concern for a
navigation-focused app, not just a cosmetic one.

This is not a crash and requires a deliberate two-tap detour rather than occurring on the single
happy path, so I'm not calling it blocking — but it's a genuine, previously-unflagged interaction
gap, it directly contradicts the code's own stated invariant, and it sits exactly in the seam this
task asked me to scrutinize (FT-17a/FT-18 non-regression). Recommend fixing before merge or as an
immediate same-session follow-up: simplest fix is either gating `driveEntryButton`'s two actions
(and ideally the rest of `recenterButtonStack`) on `!blockSelectModeActive`, or adding
`cancelBlockSelectMode()` to the `.onChange(of: driveModeActive)` handler so entering Drive Mode
from any path always cancels an in-progress block-select session.

- Where: `ios/WePark/WePark/ContentView.swift` — `recenterButtonStack` (~line 1513),
  `driveEntryButton` (~line 1580), `enterCruiseMode()` (~line 1858), `mapZStack` (~line 1247)
- Owner: `@ios-engineer`

## Compiler-catchable-error scan (the class of bug a prior QA pass missed on B4)

Specifically checked for the "`let`-with-default excluded from memberwise init" bug class flagged
in the task brief. `Segment`'s explicit memberwise `init(...)` (already on `main`, unmodified by
this PR) still has `oneway: Bool? = nil, onewayToward: String? = nil` as the only defaulted
parameters, and every `Segment(...)` construction site in B2's new test file
(`FT15B2Tests.swift`) goes through a local `ft15b2Segment(...)` helper that builds a JSON string
and calls `JSONDecoder().decode(Segment.self, from:)` — **never the memberwise initializer at all**
— so this PR cannot re-trigger that exact bug class, structurally. No other new `struct`/`class`
in this PR (`BlockRestrictionReportSheet`, `CameraCaptureView`) declares stored properties with
defaults that would interact with a synthesized memberwise init in a way that could exclude a
required parameter.

## Live-schema compliance

- `insertBlockScopedReport`'s payload (read directly in B3's `insertSingleBlockScopedPin`) is
  `pin_type, source, lifespan, lat, lng, segment_id, author_id, report_group_id, starts_at,
  expires_at, notes` — **no `created_at`** anywhere in the dict.
- The only other network call the write path makes is the rollback path, which is a plain `DELETE
  /rest/v1/pins?id=eq.<id>` — **no `PATCH`** anywhere in B2 or B3. `source`/`pin_type`/
  `report_group_id` are never touched after insert.
- The `42501` rate-limit rejection is parsed from the response body's `code` field (not just HTTP
  403 status, so an unrelated 403 can't misfire it) and surfaced via
  `BlockScopedReportError.rateLimitExceeded`'s dedicated, non-generic
  `LocalizedError.errorDescription` ("You've reported the maximum number of closures for now —
  please try again later.") — traced the full path from `submit()`'s `catch` block through to this
  string; it is never swallowed into a silent no-op or a generic fallback.

## PII (§7)

- The evidence photo is displayed exactly once, locally, pre-submit, as a 72×72 thumbnail inside
  `photoSection` — the one narrow exception the task brief allows. Never re-displayed post-submit,
  never sent to any other UI surface in this diff.
- No storage path, filename, or photo bytes appear in any string literal, error message, or log
  call anywhere in `BlockRestrictionReportSheet.swift` — confirmed by reading the full file; the
  only place `PinEvidenceUploadResult.storagePath` even exists is in B3's `PinEvidenceUploader`,
  and B2 never reads that field at all (it discards the `insertBlockScopedReport` return value
  with `_ = try await ...`).
- `submitError`'s only sources are `BlockScopedReportError`/`LocalizedError.errorDescription`
  strings, all pre-written and non-generic, none of which echo a server response, a path, or a
  filename.
- No structured name/phone field exists anywhere in the form (AC-R7) — manually confirmed: the
  only free-text input is `notes`.

## FT-17a / FT-18 regression checks

- **The specific claim the task asked me to verify — "the entry point (a third dialog action) is
  unaffected because the resting long-press dialog only shows when `driveModeActive == false`" —
  is TRUE.** I traced `showRestingActionMenu = true`'s single call site
  (`handleLongPress`, ~line 2640) and confirmed its guard is `guard !driveModeActive,
  !blockSelectModeActive else { return }`. FT-18 only restructured Drive-Mode-**active** chrome
  (`endDriveControl`, `recenterRow`, `driveActionRow`, gear-button gating), all of which are
  themselves gated on `driveModeActive`; the resting dialog and FT-18's Drive-active rows are
  disjoint by construction, confirmed by direct reading, not by trusting the PR description.
- Bottom Dock structure itself (`recenterRow`, `driveActionRow`, `DriveModeBottomCard`, gear-button
  visibility, mute-toggle placement inside `DriveModeBottomCard`) — **zero lines of
  `DriveModeBottomCard.swift` are touched by this PR** (confirmed: not in the diff stat at all).
  FT-17a's recognizer-based pinch/pan detection is also untouched (no diff to that code path).
  Nothing in this PR's own logic regresses either of those directly.
- **But see the Significant finding above** — the *interaction* between block-select mode and Drive
  Mode entry is new, untested, and does produce a state the FT-18 redesign's chrome-isolation goal
  was specifically meant to prevent. This is exactly the kind of thing the task's regression-check
  ask exists to catch, and it's real.

## Acceptance criteria checklist (spec §12, B2's slice)

- [x] AC-R1 — tap toggles selection in/out — verified via `toggledBlockSelection` unit tests + code read
- [x] AC-R2 — Both curbs auto-adds opposite side when loaded, degrades to 1-block when not, no crash — verified via `oppositeSideSegment`/`toggledBlockSelection` tests
- [x] AC-R3 — Continue disabled at zero selections — `.disabled(selectedBlockKeys.isEmpty)`, confirmed
- [ ] AC-R4 — Kevin's canonical case produces exactly 4 `pins` rows sharing one `report_group_id` — structurally verified at both the B2 (summary text) and B3 (write-path unit test) layers; **not verified end-to-end against a live/simulated network** — needs Mac + either mocked or real Supabase round trip
- [x] AC-R5 — photo required to submit — `isSubmitEnabled(hasPhoto:isSubmitting:)`, tested
- [x] AC-R6 — blank end time → computed default shown before submit matches what's actually submitted — same pure function used for both (`resolvedExpiresAt`), traced directly
- [x] AC-R7 — no structured name/phone field — manual review confirms only `notes: String`
- [x] AC-R8 — failed submit preserves form state + photo, shows retry-able error — `submit()`'s catch block only mutates `submitError`; `capturedImage`/`notes`/`startsAt`/etc. all untouched on failure
- [ ] AC-R9 — live-UI-smoke screenshot — **not run.** No Xcode/simulator on this VPS; author's PR description explicitly acknowledges this. **Mandatory Mac gate**, see below.

## Mac gates required, ordered by most-likely-to-fail-first

1. **Merge #81 (B3) first**, then rebase #82 (B2) onto the new `main` (or merge B2 as-is and expect
   the compile to fail until B3 lands — do not merge B2 before B3). No file conflicts expected
   (verified above — zero overlapping files).
2. **`xcodebuild build` + `test`** on the rebased branch. Given the interface-match verification
   above found zero mismatches, I'd bet on this passing on the first try — but "compile-unverified"
   is compile-unverified until a real `swiftc` says otherwise. Confirm 47 new tests (20 B2 + 27 B3)
   all pass, plus the existing suite (585+ as of the last verified count in HANDOFF.md) stays green.
3. **`PlistBuddy` check on the built `.app`** for both new keys (command above) — do this
   immediately after the build succeeds, before touching the simulator UI. My analysis above says
   this will very likely pass, but a hard-crash-on-tap bug is not something to take on faith.
4. **Live-UI smoke** (mount-chain PR — touches `MapViewRepresentable.swift`, `ContentView.swift`,
   `.safeAreaInset` overlay code): confirm the toolbar/ASP banner/Park Until pill layer still
   renders after this merge (the recurring #31/W8.5c-polish regression class), then walk the PR's
   own smoke checklist for the 4-blockface E 2nd St case. **While doing this smoke, specifically
   also try the Significant finding's repro** (enter block-select mode, then tap the Drive entry
   button without cancelling first) — confirm or refute the dual-state UI collision described above
   before deciding whether it's a same-session fix or a tracked follow-up.
5. Once #81 is live and this rebases: a real end-to-end submit (2 blocks, both curbs) verified
   either via Supabase directly or via the already-merged B4 consumption surfaces
   (`PinDetailSheet`/`BlockDetailView` banner) — confirms AC-R4 for real, not just at the unit-test
   layer.

## Smoke tests run

- Fetched both PR branches, pinned each to a local ref immediately (not `FETCH_HEAD`) before
  reading either diff.
- Diffed each branch against its own merge-base with `main` (not `main` directly) to exclude
  unrelated tile-regen/doc noise from an unrelated already-merged PR (#80) that had drifted `main`
  ahead of both branches' common ancestor.
- Read every line of the B2 diff (`ContentView.swift`, `MapViewRepresentable.swift`,
  `BlockRestrictionReportSheet.swift`, `project.pbxproj`, `FT15B2Tests.swift`) and the relevant
  slice of the B3 diff (`CommunityPinService.swift`'s block-scoped-report section,
  `PinEvidenceUploader.swift`).
- Hand-verified every B2→B3 call site against B3's actual signatures (table above) — no mismatch.
- Grepped for `Calendar.current` in every new/modified file in both PRs — only doc-comment mentions,
  zero actual usage.
- Grepped for direct `Segment(id: ...)` memberwise-init construction in test fixtures — none found;
  all fixtures decode through `JSONDecoder`, sidestepping the memberwise-init-default trap entirely.
- Read the full `supabase/02f-block-scoped-restrictions.sql` migration (already applied to
  production per HANDOFF.md 2026-08-13) far enough to confirm the 7d/90d ceilings and the `42501`
  rate-limit errcode match what B3's iOS constants and error-detection logic assume.
- Traced `blockSelectModeActive`/`selectedBlockKeys` through every call site in `ContentView.swift`
  to check the "mutually exclusive with Drive Mode" claim — found it false in one direction (see
  Significant finding).
- Did **not** and **could not**: compile, run unit tests, launch the simulator, or take any
  screenshot. No Xcode/Swift toolchain exists on this VPS. Everything above is static code review
  plus cross-branch interface verification, not execution.
- Cleaned up local pinned refs (`qa-b2-pin`/`qa-b3-pin`) after the review; confirmed
  `git branch --show-current` is `main` at the end of this pass, no commits made.

## What's working

- The core anti-FT-14 design (verbatim, pure, key-based block identity, no on-device
  normalization) is intact end to end — I could not find a single place where a street name gets
  re-derived, trimmed, or fuzzily matched anywhere in this PR or its B3 dependency.
- The B2↔B3 interface is the cleanest cross-stream match I've checked in this feature's QA
  history — every signature lines up exactly, and B2 stays decoupled from B3's specific error enum
  cases rather than brittle-pattern-matching them.
- `MapViewRepresentable.swift`'s touch is genuinely minimal and additive, follows the established
  `CoordinatorActions`-free "mechanical `updateUIView` sync, no camera mutation" pattern this file's
  regression history has forced the team to converge on, and the Z-order re-insertion fix
  correctly anticipates a real race (block-select active during a 60s overlay rebuild tick).
- The write-path partial-failure handling in B3 (sequential inserts, rollback-to-zero on a
  mid-batch failure, honest documentation of the one accepted orphan-storage-object gap rather than
  overclaiming it's solved) is unusually well-reasoned for a first pass, and the test suite
  (`testInsertBlockScopedReport_midBatchFailure_rollsBackPriorRows`,
  `testInsertBlockScopedReport_rateLimit403WithCode42501_throwsRateLimitExceeded`) actually
  exercises it rather than just asserting the happy path.
- Both PRs are honest and specific about what's compile-unverified and what needs a Mac — neither
  author overclaimed a result they couldn't produce on this VPS.
