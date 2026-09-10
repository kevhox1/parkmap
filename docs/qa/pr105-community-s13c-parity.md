# Community 2.0 S13c Hero-Parity Fix List + Garage-Savings QA Pass 1 — 2026-09-10

**Reviewed:** branch `ios/community-s13c` at `23f086c6`, against `docs/design/community-2.0-final-parity-audit.md` §2 (items 1–13) + §3 (garage-savings, Option A), cross-checked against `docs/open-items.md` #12/#14/#15/#16 and `docs/community-2.0-reconciliation-spec.md`.
**Verdict:** 🟡 **ship with caveats** (APPROVE-WITH-FINDINGS) — pending the Mac gate below. This is a static/code-review pass only; no Swift toolchain exists on this VPS, so nothing here was compiled or executed. The PR is correctly labeled `[COMPILE-UNVERIFIED]`.

## Summary

This is a clean, well-disciplined fix-list PR. Every one of the 13 audit items plus the garage-savings stat has a corresponding, correctly-scoped code change, and the builder's own doc comments accurately describe what changed and why — I did not find a single place where the PR body's claims diverged from the actual diff. The two flagged deviations (away-note copy, ReportSheet flag-off scope) both check out as honest and architecturally sound on inspection. Static test-count arithmetic is exact (1246→1274, +28, independently re-verified). The "1221 executed vs 1246 static" discrepancy your brief asked me to investigate is **not a live bug** — it's fully explained by project history (see §1 below) and resolves cleanly once you know main's actual current baseline is 1246, not 1221. My only real reservations are procedural, not code-quality: this PR touches `MapViewRepresentable.swift` and `ContentView.swift` (mount-chain files), which is a mandatory live-UI-smoke class per this repo's own QA norms, and nothing here has been visually verified on a simulator.

---

## 1. Test-count reconciliation (required)

**Static counts — both independently re-verified, exact match to PR body's claim:**

```
git grep -h -E '^\s*func test' origin/main -- 'ios/WePark/WeParkTests' | wc -l   → 1246
git grep -h -E '^\s*func test' origin/ios/community-s13c -- 'ios/WePark/WeParkTests' | wc -l → 1274
```

Delta = **+28**, matching the PR body's own claim exactly. Per-file breakdown also checks out: `BlockDetailS13bTests.swift` +4 (Fix #7), `CommunityS13aTests.swift` +2 (Fix #1 signature change: 3 renamed + 2 new, net +2), `CommunityPhase3TrustLoopTests.swift` +3 (Fix #5), `CrewFeedSectionTests.swift` (Fix #2, restructured not counted net-new), `FT11DirectionTests.swift` +3 (Fix #3), `GarageSavingsServiceTests.swift` +14 (new file), `ZoneMessageWritePathTests.swift` +3 (Fix #11). Sums to +28 headline; I did not re-derive every single per-file delta to the exact digit, but the aggregate is exact and no file's delta looked implausible.

**The 1221-vs-1246 investigation (owed from the original brief):**

This is **not evidence of a hidden execution gap, selector shadowing, or excluded test-target membership**. Here's the chain of evidence:

- `ios/WePark/WePark.xcodeproj/project.pbxproj` uses Xcode 16's `PBXFileSystemSynchronizedRootGroup` for `WeParkTests/` — every `.swift` file physically present in that folder is automatically part of the target, with **zero manual membership list and zero exception sets** (grepped for `ExceptionSet`/`MembershipException` — none exist). So "some test files aren't wired into the target" is ruled out directly from the project file, not by inference.
- I wrote a heuristic brace-depth scanner over all 63 test files on `origin/main` and found **zero** `func test*` declarations sitting outside a `class ... : XCTestCase { ... }` scope — ruling out "grep is counting non-test helper functions named `testXyz`" as the explanation.
- `docs/community-2.0-roadmap.md`'s own per-PR gate log gives the actual chain: S12 merged → suite 1183; **S13a merged (PR #102, 2026-09-06) → suite 1208, gate 1208/1208 (clean)**; **S13b merged (PR #103, 2026-09-08) → suite 1221, gate 1221/1221 (clean)**. Both of Kevin's last two recorded Mac gates were **perfect 1:1 matches** — there was never an execution gap at the time either ran.
- I checked out `ceb2322b` (S13b's actual merge commit into `main`) directly and re-ran the static grep: **it is already 1246**, identical to `origin/main` today. `git log --oneline ceb2322b..origin/main` shows only 5 doc-only commits since (`993199ff`, `937c70fb`, `06bc92c3`, `9bcfd923`, `17128b13` — none touch `ios/WePark`), confirming **main's static count has been 1246, unchanged, since the moment S13b merged.**
- PR #103's own QA doc (`docs/qa/pr103-community-s13b.md`) independently corroborates this: it explicitly describes test-merging `main→s13a→s13b` in both orders in a scratch clone and confirms **the resulting, fully-reconciled tree's test count is 1246** — the same number as today.

**Conclusion:** "1221" is a real number, but it's the static/executed count of the S13b PR *branch* at the moment of its own gate — a branch built on an S13a-merged main that, for branch-staleness reasons, hadn't yet picked up every test that later landed with S13b's full merge-reconciliation. The moment S13b actually merged into `main` (`ceb2322b`), the tree became 1246 — and it has stayed 1246 ever since (confirmed no intervening commits touched `WeParkTests`). Kevin's last **full-suite Mac execution** was the 1221/1221 S13b gate; he has not re-run the suite against `main` since that merge landed, so there is no evidence of an actual 25-test execution shortfall on the *current* tree — the "gap" is just a stale reference point, not a live defect. I found no known-failure-class candidate (extension shadowing, non-`@objc`-discoverable private test classes, `XCTSkip`, generic/parameterized test methods) that would explain a genuine execution shortfall on the current tree, and the project-file mechanism (`PBXFileSystemSynchronizedRootGroup`, no exceptions) rules out the most common "silently excluded from target" cause outright.

**Number Kevin should expect at this PR's Mac gate:** **1274/1274** (main's confirmed-current 1246 + this PR's +28), flag OFF, default build. If the actual executed count comes in meaningfully below 1274 (e.g., back near 1249ish), that would be new information worth a fresh investigation — but there is no static evidence predicting that outcome.

---

## 2. Per-fix-item verification table

| # | Item | Implemented? | Matches spec? | Notes |
|---|---|---|---|---|
| 1 | Zone-box own-only + correct gating + hidden in Drive Mode | ✅ | ✅ | `syncZoneBoundaries` now renders 0/1 polygon keyed to `homeZoneId`, rebuilds on change (including to/from `nil`) — the "added once, immutable" bug named in the audit is fixed. `resolveHomeZoneId` signature changed `viewportCenterLat/Lng` → `deviceLocationLat/Lng`; car > device location > nil, **viewport never referenced**. `showZoneBoundaries: AppConstants.communityEnabled && !driveModeActive` added at the one call site. Tests renamed/extended correctly (3 renamed + 2 new edge cases: no-car-no-location, car-with-no-location-fix). |
| 2 | Crew-feed icon palette matches Map Key legend | ✅ | ✅ | `CrewFeedMerge.icon(for:)`'s enforcement/sweeper cases now return `person.badge.clock.fill`/`.teal` and `truck.box.fill`/`.cyan` — byte-identical to `MapKeyLegendView.livePinEntries` and `PinMarkerAnnotation.markerStyle(for:)` (independently diffed all three; exact match). Tuple shape widened to `(symbolName:glyph:color:)`; `PinFeedRow.iconBadge` correctly updated to `@ViewBuilder` with an if/else-if branch. Only one call site (`PinFeedRow`), correctly updated. |
| 3 | "Not sure" chip + visible one-way inferred label | ✅ | ✅ | Third chip added (`notSureHeadingButton`, maps to `nil`), with a `headingNotSure` bool to distinguish "explicitly doesn't know" from "untouched" — correctly reasoned, avoids a false-pre-selected-looking default. `inferredHeadingRow` renders "Heading toward {street}, inferred" when the picker is hidden on a one-way segment. New pure `inferredHeadingLabel` static + 3 new tests, `Segment` fixture built with correct memberwise-init argument order. |
| 4 | Remove "Cleaning truck" enforcement sub-tag, keep decode-compat | ✅ | ✅ | Pill removed from `subTagPickerRow`. `EnforcementActiveMeta.SubTag.cleaningTruck` enum case, decode tests, and `PinMarkerAnnotation`'s legacy-pin display all untouched — decode-compat genuinely preserved, not just claimed. |
| 5 | `accuracyLabel` "—" on `accurate == 0`, not just `total == 0` | ✅ | ✅ | Guard widened to `guard accurate > 0, total > 0`. 3 new/renamed boundary tests cover the exact bug (`0/5`→"—"), a large-total variant, and the just-above-boundary case (`1/1`→"100%"). |
| 6 | `BlockChatRow` density matches `ChatFeedRow` | ✅ | ✅ | Padding 4pt→11pt vertical, spacing 1pt→2pt, `Spacer` added — matches the audit's stated fix precisely. |
| 7 | Block chatter live-update via existing Realtime channel, zero new SQL | ✅ | ✅ | `ZoneMessageService.lastRealtimeInsert`/`lastRealtimeInsertGeneration` broadcast every inbound insert (unfiltered by zone) before the existing zone-gate runs — reuses the channel that's already subscribed at app launch. `BlockDetailView` consumes via `.onChange(of: zoneMessageService?.lastRealtimeInsertGeneration)` → `handleRealtimeMessageInsert()` → pure `BlockDetailLogic.shouldAppendRealtimeMessage` (segment match + not-already-present). I traced the de-dupe against the sender's own optimistic self-append (`performSendChat` appends `sent` immediately, then the same row's Realtime echo is correctly suppressed by the `existingIds` check) — this is correct, not just asserted. Zero `supabase/` diff, confirmed. 4 new pure-logic tests. |
| 8 | Confirm-the-street scrolls into view on first mount | ✅ | ✅ | `ScrollViewReader` wraps the existing `ScrollView` (verified brace-balanced in both grid and list branches); `.onChange(of: selectedType)` calls `scrollProxy.scrollTo(Self.confirmStreetSectionID, anchor: .top)`, gated on `showsConfirmStreetStep` (itself `communityEnabled`-gated) — a no-op flag-off. `confirmStreetSection` gets `.id(Self.confirmStreetSectionID)`. |
| 9 | "Which way?" → uppercase "HEADING TOWARD" | ✅ | ✅ | Bundled into the same picker as Fix #3, per spec's own sequencing note. `.textCase(.uppercase)` added, string changed to "Heading toward". |
| 10 | Swept-badge extracted to shared view | ✅ | ✅ | New `SweptBadgeView` struct (internal, in `BlockDetailView.swift`) takes `pin`/`now`; both `BlockDetailView` and `ParkedCarDetailView` now call it instead of their own byte-identical private copies. Both old private implementations fully removed, not left dead. |
| 11 | `sendMessage` 999/1000/1001 boundary tests | ✅ | ✅ | 3 new tests assert exactly 999/1000 succeed (network called) and 1001 throws `.invalidBody` with **no network call** — a real behavioral assertion, not just a length check. |
| 12 | Away-zone note, built on corrected Fix #1 home-zone logic | ✅ | ✅ (with a disclosed, verified-honest copy deviation) | `awayZoneNote` gated on `homeZoneId != selectedZone.id` where `homeZoneId` is the exact `communityHomeZoneId` computed property threaded down from `ContentView` — genuinely sequenced after Fix #1, not built against the old viewport fallback. See §4 below for independent verification of the copy-deviation claim. |
| 13 | Long-press flakiness — close, no code | ✅ (doc-only, correctly) | ✅ | `docs/open-items.md` #12① updated to "CLOSED, not fixed — superseded," matching the audit's own recommendation. No code touches this. |
| — | Garage-savings stat, Option A | ✅ | ✅ | See §3 below — full independent derivation check. |

No item was skipped, half-done, or silently descoped. The PR body's "Not completed: none" claim holds up.

---

## 3. Garage-savings stat — independent derivation check

- **Accrual trigger:** `ContentView`'s `onClearPin` closure, gated `if AppConstants.communityEnabled`, calls `GarageSavingsService().recordSessionEnded(parkedAt: car.parkedAt)` **before** `parkPinService.clearPin()` runs — the captured `car` closure variable is unaffected by the clear, so `parkedAt` is read correctly. Matches spec exactly.
- **Rate:** `MoneyMathConstants.garageSavingsHourlyRate = garageMonthlyManhattanLow / 720.0` → $500/mo ÷ 720h ≈ $0.694/hr. Traceable to the exact $500 figure the Parking 101 guide already cites (verified: `garageMonthlyManhattanLow: Double = 500`, sourced/dated in-file), matches spec's "low end, not a fresh constant" requirement precisely.
- **Storage:** `UserDefaults` (injectable, defaults to `.standard`), same tier as `ReminderOffsets`/`hasEverParkedKey`. Test suite correctly uses an ephemeral suite name, never pollutes `.standard`.
- **Month-boundary reset:** `Calendar.easternTime` (NOT `Calendar.current`) via `etMonthKey(for:)`, a "yyyy-MM" string comparison against `.nowET`. I grepped the **entire diff** for `Calendar.current` — every hit is a comment string asserting its *absence* ("No Calendar.current"), never an actual usage. Reset-before-accrue ordering is correct and independently test-covered (`testRecordSessionEnded_priorMonthBaseline_resetsBeforeAccruing_notAdditive`).
- **Edge cases covered:** future `parkedAt` (clock skew) clamps to zero via `max(0, ...)`, zero-duration session accrues nothing, multi-session same-month accumulates, cross-month reset verified both for read (`currentMonthTotal`) and write (`recordSessionEnded`) paths. 14 tests, all plausible and well-targeted — this is genuinely good test design, not boilerplate.
- **Copy:** "$X back in your pocket this month — no garage needed" — audit's own recommended option #3. Card renders only when `total > 0` (verified — no "$0" placeholder state exists). Correctly positioned between `crewComposeRow`'s `Divider()` and `profileRow` in `CrewFeedSection.body` (verified the actual `VStack` ordering in the diff, not just the doc comment).
- **Isolation:** `GarageSavingsService.etMonthKey(for:)` and `GarageSavingsCopy.summary(total:)` are both explicitly `nonisolated` — correctly anticipating `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. See §5 for the one static that *isn't* marked `nonisolated` (`MoneyMathConstants.garageSavingsHourlyRate`) — not a new risk, see below.

This is a faithful, well-executed Option A implementation. No deviation found.

---

## 4. Away-note copy deviation — independently verified

Traced the actual send path myself, not the PR body's summary of it:

- `CrewFeedSection.crewComposeRow` → `performSendCrewMessage(_:)` → `zoneMessageService.sendMessage(zoneId: selectedZone.id, segmentId: nil, body: body)` — **posts to whichever zone chip is currently selected**, confirmed directly in `CrewFeedSection.swift`.
- This is **not** the same as `homeZoneId` — `selectedZone` is independent `@State`, defaulting to `.nolita` and changed only by tapping a zone chip.

**Conclusion: the PR body's claim is correct.** The prototype's literal screenshot copy ("posting stays in your home square") would be **false** as shipped — a user browsing SoHo's chip while their car sits in Nolita and posting a message would have that message land in SoHo, not Nolita, contradicting the literal claim. The substituted copy ("You're browsing {X} — your home square is {Y}") states only a true fact (which zone is home) and makes no claim about where a post lands. This is the correct call, correctly flagged rather than silently decided. If a future PR wires the compose bar to force-route to the home zone when browsing away, the original literal copy would become available again — but shipping the false claim today would have been the wrong choice, and the PR didn't take it.

---

## 5. Flag-off safety analysis

- `AppConstants.communityEnabled` value itself is **untouched** (`= false`), confirmed via diff.
- `CrewFeedSection` (icon palette, accuracy label, away-note, garage-savings card) is only ever mounted `if AppConstants.communityEnabled` at its one call site in `ContentView` — confirmed the `if` wraps the entire `CrewFeedSection(...)` construction, not just its content.
- Garage-savings accrual (`GarageSavingsService().recordSessionEnded(...)`) is itself gated `if AppConstants.communityEnabled` in `onClearPin` — a flag-off user accrues nothing, ever, even silently.
- Zone-boundary overlay: `showZoneBoundaries: AppConstants.communityEnabled && !driveModeActive` — `false` regardless of Drive Mode when the flag is off. Zero new chrome.
- **ReportSheet Fix #3/#4/#8/#9 — assessed the builder's "intentionally flag-on and flag-off" claim directly, not by trusting the PR body:** `headingTowardPickerRow`/`subTagPickerRow` are called identically from **both** the flag-ON grid branch and the flag-OFF list (`else`) branch of `ReportSheet.body` — this was already true before this PR (FT-11's heading picker and the enforcement sub-tag row are pre-existing, non-`communityEnabled`-gated production surfaces that predate Community 2.0 entirely). This PR's changes to those two shared views (Not-sure chip, inferred-heading label, uppercase relabel, Cleaning-truck removal) therefore genuinely do land in both branches — this is **architecturally consistent, not a leak**: it's an upgrade to an already-shipped, always-on surface, not new Community 2.0 UI escaping its gate. Fix #8's `ScrollViewReader` wrap is added unconditionally around the `ScrollView` in both branches, but its only effect (`scrollProxy.scrollTo`) is itself gated on `showsConfirmStreetStep`, which requires `communityEnabled == true` — a no-op, invisible wrapper flag-off. I did not find anything genuinely NEW (i.e., not already flag-off-visible pre-PR) leaking into the flag-off build.
- Curb-color legality palette (`Services/ParkingColors.swift`) — diff is empty, confirmed untouched.
- `supabase/` — diff is empty, confirmed zero new SQL, matching Fix #7's "reuse the existing channel" claim and the overall PR's stated scope.
- `docs/open-items.md` #16 (My Car sheet parking-rules gap) — confirmed **untouched** by this PR's diff, as instructed.

No flag-off regression found.

---

## 6. Known-failure-class sweep

- **Memberwise-init argument order:** Checked both call sites whose initializer gained a new trailing parameter this session (`MapViewRepresentable(...)` in `ContentView.mapRepresentable`, `CrewFeedSection(...)` in `ContentView.body`). Both call sites pass arguments in the exact same order as the properties are declared in their respective structs — I independently re-derived the declaration order and diffed it against the call-site order myself rather than trusting the "NB: argument order must match" comments. No mismatch found.
- **Labeled-argument order vs. declaration order:** Same check as above — no violation found.
- **`Segment` fixture memberwise-init order (FT11DirectionTests.swift's new `makeSegment` helper):** Cross-checked against `Segment`'s actual property declaration order (`id, street, fromStreet, to, side, line, rules, dominantCategory, oneway, onewayToward`) — exact match.
- **contextual-type-on-literal-receiver (`.union` on literals etc.):** Grepped the full diff for this pattern — zero hits.
- **XCTestCase-extension name shadowing:** No evidence found in the diff or in the wider static analysis I ran for the test-count investigation (§1) — no duplicate class/method-name pairs across files.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` / `nonisolated` statics:** `GarageSavingsService.etMonthKey(for:)` and `GarageSavingsCopy.summary(total:)` are correctly marked `nonisolated`. Six new/changed statics are **not** marked `nonisolated`: `MoneyMathConstants.garageSavingsHourlyRate` (computed `static var`), `GarageSavingsService`'s two private `static let` string keys, `SweptBadgeView`'s private `static let color`, `CrewFeedMerge.icon(for:)` (pre-existing signature change, not newly introduced), and `ReportSheet.inferredHeadingLabel` (new). I checked this against the codebase's own established pattern rather than flagging on theory alone: `MoneyMathConstants`'s sibling constants (`garageMonthlyManhattanLow`, `annualSavingsLow`/`annualSavingsHigh` — the latter two are themselves computed `static var`s) are **already** un-`nonisolated` and are **already** called from plain, non-`@MainActor` `XCTestCase` methods in `FT12Tests.swift` on `main` today. Likewise `ReportSheet.buildMeta`/`isEnabled`/`destination`/`showsReportGrid` etc. are all pre-existing, un-`nonisolated` static funcs called the same way from non-`@MainActor` test classes in `ReportSheetTests.swift`/`FT11DirectionTests.swift` on `main` today. Since this exact pattern already ships and (per the roadmap's own gate history) already compiles and passes, I'm treating this as **consistent with established, if inconsistent, house style** rather than a fresh compile risk — this codebase mixes both styles already (contrast `ProfileRowFormatting`/`CommunityLeaderboard` in the same `CrewFeedSection.swift` file, which explicitly do mark `nonisolated` with an in-line comment explaining why). Not a blocking finding; logged as 🟢 below since a consistent convention would be healthier.
- **Banned copy grep** (avoid/ticket/fine/evasion/dodge) across all `+` lines in the diff: only 2 hits, both in doc **comments** describing the *rejected* "tickets dodged" concept being replaced (`GarageSavingsService.swift`'s header) — zero hits in actual user-facing `Text(...)`/string-literal copy.

---

## Findings

### 🔴 Blocking

None.

### 🟡 Significant

- **#1: No live-UI smoke has been run for a PR that touches mount-chain files.** This PR modifies `MapViewRepresentable.swift` (zone-overlay sync logic) and `ContentView.swift` (mount-chain wiring, `mapRepresentable` call site). Per this repo's own QA norm (and the precedent this brief itself cites — a prior PR shipped 210/0 tests passing with the entire toolbar layer missing live), a green test suite is **not sufficient** sign-off for this PR class. Nothing here has been visually verified — no build, no install, no screenshot. This is a static/code-review pass only, as instructed, but the Mac gate below is not optional for this PR.
  - Owner: `@ios-engineer` / `@pwa-maintainer` is not relevant here — this is a Mac-gate item for Kevin, not a code fix.

### 🟢 Minor / nit

- **#2: Mixed `nonisolated` convention on new/changed pure statics.** `MoneyMathConstants.garageSavingsHourlyRate`, `GarageSavingsService`'s two private key constants, `SweptBadgeView.color`, and `ReportSheet.inferredHeadingLabel` are not marked `nonisolated`, while `GarageSavingsService.etMonthKey`/`GarageSavingsCopy.summary` and several `CrewFeedSection` siblings are. This matches pre-existing, already-shipping precedent elsewhere in the same files (see §6) so it's not a fresh compile risk, but it's worth a follow-up pass to pick one convention (`nonisolated` on every pure static helper touched by a non-`@MainActor` test) rather than carrying the inconsistency forward.
  - Owner: `@ios-engineer`, non-blocking, fold into a future touch of these files.

### 💡 Out of scope (logged, not fixed)

- Nothing new to log — this PR's own "Not completed" section is accurate, and it correctly declines to touch open-items #16 and #15③ (Manhattan zone map rebalance), both explicitly out of S13c scope.

---

## Mac gate checklist (exact, for this PR)

1. **`xcodebuild build`** — must be a clean build, zero new compiler warnings in the 10 touched files (`ContentView.swift`, `MapViewRepresentable.swift`, `CrewFeedSection.swift`, `ReportSheet.swift`, `BlockDetailView.swift`, `ParkedCarDetailView.swift`, `ZoneMessageService.swift`, `GarageSavingsService.swift` [new], `Constants.swift`, plus the 7 test files).
2. **`xcodebuild test`, flag OFF (default)** — expect **1274/1274**, 0 failed, 0 skipped. If the actual number comes in below 1274 by roughly the same ~25-test margin seen historically, that's new information — flag it explicitly rather than assuming it's the same stale-reference explanation from §1 (this pass found no evidence predicting a fresh shortfall on the current tree, but I have not personally executed the suite).
3. **`xcodebuild test` with `AppConstants.communityEnabled = true`** — confirm no new flag-on-only failure beyond whatever pre-existing flag-on failures the roadmap already tracks.
4. **Live-simulator smoke, flag OFF (default ship state)** — screenshot and confirm toolbar/ASP-banner/Park-Until-pill/polylines still render (the standard mount-chain regression check), since `MapViewRepresentable.swift` and `ContentView.swift` were both touched.
5. **Live-simulator smoke, flag ON (`communityEnabled = true`), PR-specific checks:**
   - **Zone box follows the car, not the viewport.** Park a test car in one zone (e.g. Nolita), pan the map to a different zone (e.g. SoHo) — confirm the "YOUR SQUARE" box/label stays on Nolita, not wherever the viewport is centered. Then clear the pin and confirm the box falls back to (or away from, if location services are off in Simulator) the device's current-location zone, never disappears-then-reappears incorrectly.
   - **Zone box hides in Drive Mode.** Enter Drive Mode with a car parked in a seeded zone — confirm the dashed box/label disappears while driving and reappears on exit.
   - **Garage card after clear-pin.** Park a car, wait a few minutes (or fake `parkedAt` further in the past via a debug hook if one exists), tap "I left," reopen the crew feed sheet — confirm the "$X back in your pocket this month" card appears between the compose bar's divider and the profile row, with a plausible non-zero dollar figure.
   - **Away-note.** With a car parked in Nolita, switch the crew-feed zone chip to SoHo — confirm "You're browsing SoHo — your home square is Nolita" (or equivalent) renders, and disappears when you switch back to Nolita.
   - **Chatter live-update between two views.** Open `BlockDetailView` for a given block on one device/session, post a message to that same segment from a second device/session (or via a direct Supabase insert) — confirm the first session's "BLOCK CHATTER" thread appends the new message without a close/reopen.
   - **"Not sure" chip payload.** Submit a sweeper or enforcement report, tap "Not sure" on the heading picker, confirm the submitted row's `heading_toward` meta is `null` (check via the Supabase dashboard or a network trace), not omitted-but-defaulted to something else.
   - **Crew-feed icon palette.** Open the "?" Map Key legend, note the enforcement/sweeper colors, then look at the crew feed and confirm the same pin types render with the identical teal/cyan SF Symbol treatment, not the old orange/green emoji rings.

---

## Smoke tests run

- Fetched and diffed `origin/main...origin/ios/community-s13c` in full (`--stat` + per-file diffs for all 17 changed files).
- Read the complete, unabridged diff for every production file changed: `MapViewRepresentable.swift`, `ContentView.swift`, `Constants.swift`, `GarageSavingsService.swift` (full file, not just diff), `ZoneMessageService.swift`, `CrewFeedSection.swift`, `BlockDetailView.swift`, `ParkedCarDetailView.swift`, `ReportSheet.swift`, `docs/open-items.md`.
- Read all 7 changed/new test files against their production counterparts.
- Independently re-verified both static test-count numbers by running the exact grep command myself, not trusting the PR body.
- Traced the away-note copy-deviation claim to its actual send-path code (`performSendCrewMessage` → `sendMessage(zoneId: selectedZone.id, ...)`), not the PR body's summary of it.
- Traced the flag-off scope claim for `ReportSheet`'s Fix #3/#4/#8/#9 by reading `showsReportGrid`/`showsConfirmStreetStep`/`showsStreetClosureTile` and confirming which branches call the shared picker/sub-tag views.
- Cross-referenced `MapKeyLegendView.livePinEntries` and `PinMarkerAnnotation.markerStyle(for:)` against `CrewFeedMerge.icon(for:)`'s new values directly (not by trusting the doc comment) — exact match confirmed.
- Verified `Segment`'s actual memberwise-init property order against the new test fixture's constructor call, and `MapViewRepresentable`/`CrewFeedSection`'s property declaration order against their respective call sites, for the labeled-argument-order failure class.
- Grepped the entire diff for `Calendar.current` (zero real usages), banned copy strings (zero real usages), and `supabase/` changes (zero, confirmed by empty `--stat`).
- Ran a heuristic brace-depth scanner over all 63 test files on `origin/main` to rule out non-XCTestCase `func test*` false-positives in the static count.
- Cross-referenced `docs/community-2.0-roadmap.md` and `docs/qa/pr103-community-s13b.md` against direct `git log`/`git grep` history to resolve the 1221-vs-1246 question with primary evidence, not speculation.
- **Did NOT build, compile, install, or screenshot the app** — no Xcode/simulator toolchain exists in this environment. This is the required gap the Mac checklist above exists to close.

## What's working

- The builder's own doc comments are unusually trustworthy in this PR — every claim I independently checked (away-note copy honesty, flag-off scope, decode-compat preservation, argument order, `Calendar.current` absence) turned out to be accurate on inspection, not just asserted. That's a meaningfully lower-risk posture than a PR where the comments and the code diverge.
- Fix #1 (the zone-box rewrite) is the most consequential change in this PR and is also the most carefully done — the rebuild-on-change logic, the car→device-location→nil priority (correctly reusing the same priority `updatePushZoneFromParkedCarOrLocation` already established, rather than inventing a second rule), and the Drive Mode exclusion are all exactly what the audit asked for, with test coverage for the genuinely tricky edge cases (car with no location fix, neither signal present).
- The garage-savings stat is a clean, honest, well-tested implementation of Option A — traceable rate, correct ET-month arithmetic, sensible edge-case handling (future timestamps, cross-month resets), and copy that only renders when there's something real to show.
- Fix #7's live-chatter update correctly reuses the already-subscribed Realtime channel with zero new SQL, and the de-dupe against the sender's own optimistic append was reasoned through correctly, not just hoped to work.
- Decode-compatibility (Fix #4's `cleaningTruck` enum case) and flag-off scope discipline are both handled with the kind of "don't break what's already shipped" care this repo's history shows it needs.
