# Stoop Phase 4 My Car (B7) QA — PR #205

**Reviewed:** branch `feat/stoop-phase4-mycar` at `ee091e2e`, merged locally with `origin/main` 7570733b (already up to date, no conflicts), against DECISIONS.md and the `b7-*` mocks
**Verdict:** MERGE-WITH-FOLLOWUPS

## Summary
The screen does what Kevin asked: header, one verdict block, one reminder row, a big "I left", signs on demand. The verdict is the map callout's own `WPNeighborVerdict.resolve` (no window), so the two cannot disagree. Unclear, no-data and unmatched curbs are never legal and promise no reminders. The reminder preview mirrors the scheduler's arithmetic and the scheduler is untouched. No blocking issues; follow-ups are wording/scope.

## Tests / builds
- WePark full suite (`-parallel-testing-enabled NO -jobs 4`, iPhone 17 Pro Max sim): 3079 tests, 1 skipped, 0 failures (includes the 20 new `StoopPhase4MyCarTests`). No known flakes tripped.
- WeParkClip, ClipLiveActivities, WeParkLiveActivities: BUILD SUCCEEDED.
- Release device build (`-sdk iphoneos -configuration Release`, signing off): BUILD SUCCEEDED. `strings` for `wp4Showcase`, `wp3Showcase`, `wp2bShowcase`, `WPPhase4Showcase`: 0 hits. Control: Debug `WePark.debug.dylib` has `wp4Showcase` (1). The showcase file is wrapped in `#if DEBUG` and its ContentView mount sits inside the `#if DEBUG` block.
- Live smoke through `-wp4Showcase dont` and `meter` on the sim, screenshots read: "Move your car now / No parking / Street cleaning until 10:30 AM. Free after that." with "I moved it"; "Pay the meter until 7 PM" with signs link. Both render correctly.
- NOT verified: flag-on live map flow (park a car, open My Car via the real mount, real "I left", real Tell neighbors / Spot Pass submit). Mac load was 150-400 throughout, so I did not flip flags and rebuild. Recommend one device/sim pass with flags on before TestFlight.

## Acceptance checklist
- [x] 1 Verdict identical to the map callout: `WPMyCarLogic.verdict` calls `WPNeighborVerdict.resolve(... windowEnd: nil, trip: nil ...)`, the same call as `carCallout`; only labels are re-worded. Active restriction -> "Move your car now"; meter active -> "Pay the meter until"; meter first -> "Meter starts"; neighbor reports only stricter; leading "Today" dropped; "midnight" comes from `WPCurbCopy.when`; multi-day reads "Mon 11/30 9:00 AM". The engine skips a suspended ASP day (suspended shot reads Legal until Mon, not Thu).
- [x] 2 Unclear / no data / nil segment: never legal (`isLegalNow` false, `offersReminders` false), "No reminders for this curb".
- [x] 3 Arrow signs via `WPSignList`; arrow restriction resolves red; no "First 20 ft" / "past it" strings.
- [x] 4 Reminders 15/30/1h/2h + night before bound to `ReminderOffsets`, `schedule`, `cancelAllThenSchedule` (same calls as `MyCarSheetV2View`). Preview filters `fireDate > now` like `enqueuePresets`; night-before uses the same ET 8 PM wall clock. Nothing under `Services/` changed, so flag-off scheduling is byte-identical.
- [x] 5 "I left" -> `onClearPin` -> `performClearParkedCar` (cancels notifications, clears pin). Tell neighbors uses the V2 `insertCrowdPin` params and identity gate; Spot Pass uses the shared `myCarSpotPassAction`. (Read, not exercised live.)
- [x] 6 Flag combos: `MyCarSheetVariant.resolve` is legacy when `myCarSheetV2Enabled` is off, `.stoop` only with `designSystemV2Enabled` too, else `.v2`; unit-tested.
- [~] 7 Type cap at AX3: see finding #2.
- [x] 8 DEBUG guards verified above.

## Findings

### Blocking
None.

### Significant
- **#1: Suspension note can contradict the verdict**
  - Where: `WPMyCarLogic.suspensionNote` (WPMyCarLogic.swift, in the "Street cleaning suspension" section) and its unconditional use in `WPMyCarV2View.swift` body (`if let note = suspensionNote`).
  - What: the note says "Street cleaning is suspended today ... You don't have to move the car." whenever the curb has a cleaning rule on that day, without checking the verdict. If the same curb has another restriction in force (no standing/no parking, a neighbor report) the screen shows "Move your car now" (or "Move by") with "You don't have to move the car." right below it. Same for the tomorrow note.
  - Expected: never an affirmative "you don't have to move" the verdict does not back. Show it only when the verdict is a legal variant, or drop the sentence.
  - Repro: curb with ASP Mon/Thu plus an anytime no-standing rule, on a suspended Thursday. No test covers it.
  - Owner: `@ios-engineer`

- **#2: AX3 cap ignores AX4/AX5 users**
  - Where: `WPMyCarV2View.swift:222` `.dynamicTypeSize(...DynamicTypeSize.accessibility3)`.
  - What: no other screen in the app caps type; the brief says "through the largest accessibility sizes without truncating critical information" and mock B7.10 is AX5. Nothing truncates (verdict wraps, content scrolls, "I left" pinned) but AX4/AX5 users get smaller text than they chose on the screen most likely read in a hurry.
  - Expected: honor AX5 (e.g. unpinned layout where everything scrolls at AX sizes) or get Kevin's explicit sign-off on the cap.
  - Owner: `@ios-engineer` (design call)

### Minor
- **#3:** "You'll get N reminders" ignores that the scheduler bails when notifications are muted (`notificationsMutedKey`) or permission is denied. Same gap as the V2 sheet, but the Stoop copy is more specific. Consider a "Notifications are off" line.
- **#4:** Restrictions beyond the 168 h look-ahead: the view shows no reminder row while the scheduler would still schedule. Under-promise, safe.
- **#5:** `.dont` hides "Leaving soon?" (Tell neighbors / Spot Pass) entirely (`showsLeavingSoonCard`); a behavior change from the V2 sheet, arguably right.
- **#6:** Unbuilt B7 mock items (Undo toast, Walk there, mini-map, karma sticker, "tell me when free again", meter limit reminder) are accurately disclosed in the PR body.

## What's working
Single source of truth for the verdict; stricter-only neighbor logic; reminder summary computed from the scheduler arithmetic (DST test); `#if DEBUG` hygiene confirmed in a device Release binary; 20 focused tests; scheduler untouched; screen is genuinely quieter than the old sheet.

**Verdict: MERGE-WITH-FOLLOWUPS** (#1 soon; #2 needs a decision from Kevin).
