# FT-12 Parking 101 Guide — QA Pass 1 — 2026-07-09

**Reviewed:** PR #65, branch `ios/ft12-parking-guide` at `1ec4f05` (merge-base with `main`: `893cf51`), against `docs/ft12-beginners-manual-spec.md` (all 7 OQs Kevin-approved as recommended).
**Verdict:** 🟡 ship with caveats

## Summary

The build compiles clean, the full suite passes with zero regressions (532/0, up from a 515 baseline), and the ContentView diff is exactly as narrow as claimed — banner mount + one `ActiveSheet` case + a one-line `handleMapTap` guard, with `LocationService`/`MapViewRepresentable`/`handleLocationUpdate` untouched, so this PR stays trivially rebasable over TF2-16. I drove a genuinely fresh install on my own dedicated simulator and directly observed the first-launch banner render, non-blockingly, above an intact map/toolbar/ASP-banner chain; auto-hide fired at ~8s; the `UserDefaults` gate persisted; and a relaunch showed no banner. The one thing I could not close is the same gap the builder disclosed — no interactive tap-through of Settings → Parking 101 was possible in this sandbox (osascript coordinate-clicks landed on the map, not the gear button, on two calibrated attempts; no idb/cliclick available). The main content-accuracy issue is that the Sign School's "3-tier restriction ladder" — explicitly billed as "the single most-misunderstood distinction for new drivers" — never states that a No Parking sign permits loading/unloading of **merchandise**, not just passengers, which is the actual statutory distinction (VTL §129-a/§129-b) separating it from No Standing. This text is inherited verbatim from the spec itself, so it's not an engineering deviation, but it ships to users teaching NYC parking law and is worth a follow-up pass regardless of where it originated.

## Acceptance criteria checklist

- [x] AC-1: "Parking 101" row in `SettingsView` Help section, above "Help & FAQ" — verified by code read (`SettingsView.swift:77-90`, inside existing `NavigationStack`) and passing `xcodebuild` build.
- [x] AC-2: `ParkingGuideView` renders all four sections (Pitch, Sign School, Color Legend, Rookie Mistakes) via quick-jump chips — verified by code read (`ParkingGuideView.swift`, `ParkingGuideSectionTests`); **not independently verified via live navigation** (see Finding #4 / gap).
- [x] AC-3: `FAQHelpView` cross-links to `ParkingGuideView` — verified by code read (`FAQHelpView.swift:90-108`, top of Section 1).
- [x] AC-4: `SignPlateView` renders only real sign wording, no invented icons on the plate face, non-empty `.accessibilityLabel` — verified by code read of every `SignSchoolSectionView` plate instance; broom icon confirmed confined to section-header `Label` only, never the plate. See Finding #1 for a content-accuracy nuance (not a plate-face violation).
- [x] AC-5: all Pitch dollar figures sourced from `MoneyMathConstants`, doc-commented with source + pull date — verified; `grep` confirms zero inline dollar literals in `PitchSectionView.swift`; `MoneyMathConstantsTests` assert the 12× auditability claim and the exact spec-cited $4,800–$12,000 figures.
- [x] AC-6: Color Legend reuses exact `ParkingColors` constants, all five states listed — verified: `ColorLegendSectionView.swift` references `ParkingColors.restricted/.restrictionComingSoon/.meteredActive/.freeComfortably/.unknown` directly, no new hex/RGB literals; 6h threshold framing matches `docs/design/ios-mvp-palette.md` §2.2 almost verbatim.
- [x] AC-7: first-launch banner shows at most once, dismissible, non-blocking, mutually exclusive with Drive Mode bottom card / Park Until pill — verified live on a fresh install (see Smoke tests). See Finding #2 for the deviation-#1 reasoning.
- [x] AC-8: Dynamic Type support, `SignPlateView` wraps not clips, capped at `.accessibility3` — verified by code read (`.dynamicTypeSize(...DynamicTypeSize.accessibility3)` + `.fixedSize(horizontal: false, vertical: true)` on `SignPlateView`; body text unrestricted). Live-verified only for the banner's own text (wrapped cleanly at accessibility-XXL, no truncation); **`SignPlateView`/`ParkingGuideView` itself not live-verified** — see gap.
- [x] AC-9: Dark Mode chrome adapts, sign plates stay light/white — verified by code read (`Color.white` hardcoded, comment cites OQ-7 rationale). Live-verified only for the banner/map chrome (correctly dark-adapted); **plate-specific dark-mode rendering not live-verified** — see gap.
- [x] AC-10: no PWA/`supabase/**`/`tiles/**` changes — verified: `git diff --stat` against the true merge-base shows exactly 13 files, all iOS + one docs file, matching the PR's own file list from `gh pr view`.
- [x] AC-11: full suite passes, zero regressions — verified: 532 passed / 0 failed, `** TEST SUCCEEDED **`, both on a cold `xcodebuild clean build` and a subsequent `xcodebuild test` on my own dedicated simulator. See Finding #3 for a test-count nit.
- [ ] AC-12: engineer screenshot evidence — the PR description asserts screenshots were captured but none are attached to the PR body as images (only prose description of what was seen). Not independently blocking since I captured my own, but flagging the AC's literal letter wasn't met by the PR artifact itself.

## Findings

### 🟡 Significant

- **#1: "No Parking" ladder entry omits the merchandise-loading allowance — the actual legal distinction from "No Standing"**
  - Where: `docs/parking-101-content.md:59-63` (the 3-tier table) and `ios/WePark/WePark/Views/ParkingGuide/SignSchoolSectionView.swift:60-100` (`restrictionLadderSubsection`/`ladderRow`).
  - What: The "NO PARKING" row's "You may..." cell reads "Stop briefly to load/unload with the driver present." The real NYC/VTL distinction (VTL §129-a "Parking" vs §129-b "Standing") is that No Parking permits stopping to load/unload **passengers or merchandise**, while No Standing permits **only passengers** — that's the entire reason the two exist as separate categories. The current copy frames the difference around "driver present," which is a secondary/derived detail (a driver actively loading cargo is necessarily present), not the actual statutory test. A reader could walk away believing "driver stays in the car" is sufficient for No Parking compliance, when in fact idling with no active loading/unloading is still a violation there too.
  - Expected: The No Parking cell should explicitly say something like "Stop to load/unload passengers **or merchandise**, actively — not just idle with the driver present," making the parallel to No Standing's "passengers only" restriction legible. This is exactly the distinction the content doc itself calls "the single most-misunderstood distinction for new drivers" (§3b), so precision here matters more than anywhere else in the guide.
  - Repro: Open Sign School → 3-tier ladder (code read confirms; not blocked on live nav).
  - Note: This exact phrasing is lifted verbatim from `docs/ft12-beginners-manual-spec.md` §3(b) (Kevin-approved) — the engineer did not invent it, they correctly transcribed the spec. Flagging regardless per the QA brief, since the content ships to users teaching real parking law either way. Fix requires touching the spec text, `docs/parking-101-content.md`, and `SignSchoolSectionView.swift` together.
  - Owner: `@ios-engineer` (content + code); loop in whoever owns spec updates for the doc text.

- **#2: Interactive Settings → Parking 101 tap-through not independently verified — same gap the builder disclosed, not closed**
  - Where: Live-UI smoke, this session.
  - What: No `idb`/`cliclick` available; `osascript`/System Events accessibility clicks work in principle (unlike the builder's `-25204` failure, my session had `UI elements enabled = true`), but the simulated device's UI is rendered as an opaque bitmap to macOS accessibility — there's no element tree inside the guest OS to target, only raw screen coordinates. Two independently-calibrated coordinate clicks at the gear icon (computed from the Simulator window's accessibility frame → screenshot-pixel mapping) both missed and landed on the map instead (no crash, no unintended state change — confirmed via before/after screenshots).
  - What I verified instead: (a) `SettingsView`'s "Parking 101" `NavigationLink` and `FAQHelpView`'s cross-link both construct `ParkingGuideView()` — the identical view constructor exercised by the banner's `.sheet` path, which I *did* trigger live (see Smoke tests); (b) the full suite compiles and passes with `ParkingGuideActiveSheetTests` exercising the `ActiveSheet.parkingGuide` wiring; (c) `xcodebuild clean build` succeeds, meaning `NavigationStack { ParkingGuideView() ... }` type-checks in both the Settings and banner-sheet contexts.
  - Expected (per spec AC-12 / task lifecycle norm): a live, on-device tap-through confirming the Settings row navigates correctly.
  - This is not a code defect — I have high confidence the navigation works given the shared-constructor evidence above — but the letter of "live-verified" is not met. Recommend Kevin's on-device pass (§8 step 6 of the spec) do the literal tap, or a follow-up QA session with `idb` installed.
  - Owner: N/A (verification gap, not a bug) — Kevin on-device smoke closes this.

### 🟢 Minor / nit

- **#3: PR description claims "531 passed... 15 new FT-12 tests"; actual is 532 passed / 17 new FT-12 tests.**
  - Where: PR #65 description "Test plan" section vs. my own `xcodebuild test` run (`FT12Tests.swift`: `ParkingGuidePromptGateTests` ×4, `MoneyMathConstantsTests` ×6, `ParkingGuideSectionTests` ×5, `ParkingGuideActiveSheetTests` ×2 = 17 methods).
  - What: Off by one on the suite total (532 vs. 531) and off by two on the new-test count (17 vs. 15) — harmless, tests all pass, but matches a known pattern already logged in this repo (`docs/field-testing-log.md` "FT10Tests header test-count arithmetic wrong (says 525, actual 514)"). Worth a quick habit fix: count methods programmatically before writing PR descriptions.
  - Owner: `@ios-engineer`.

- **#4: `SignPlateView` fixed-width frame (120pt) inside the ladder row could compress at very large Dynamic Type**
  - Where: `SignSchoolSectionView.swift:105` (`plate.frame(width: 120)` in `ladderRow`).
  - What: `SignPlateView` itself wraps rather than clips (verified in code), so this shouldn't truncate text, but a 120pt-wide fixed frame at `.accessibility3` will force each of the three ladder plates ("NO PARKING," "NO STANDING," "NO STOPPING") into a narrow, tall column next to their allowed/not-allowed captions. Not verified live (blocked by the same navigation gap as Finding #2) — flagging as a visual-polish risk to check on Kevin's on-device Dynamic Type pass, not a functional bug.
  - Owner: `@ios-engineer` if Kevin's on-device pass finds it cramped.

- **#5: AC-12 screenshot artifacts not attached to the PR itself**
  - Where: PR #65 description.
  - What: The PR narrates what screenshots showed but doesn't embed image attachments in the PR body. Doesn't block — I independently captured equivalent evidence — but the literal AC-12 ask ("captures a simulator screenshot... as part of the PR") wants the artifact in the PR, not just a text summary of having looked at one.
  - Owner: `@ios-engineer`, cosmetic for future PRs.

### 💡 Out of scope (logged, not fixed)

- Full pan-based banner auto-dismiss (deviation #1, disclosed and reasoned by the builder) — deferred until TF2-16's region-change plumbing is free to touch. I agree with the builder's reasoning: tap + X + 8s timer already satisfies AC-7's literal text ("shows at most once... is dismissible... does not block map pan/tap/long-press at any point while visible") since the map remains fully pannable underneath the banner even without pan-triggered dismissal — the banner just persists a beat longer on a pan-only interaction than the spec's ideal. Reasonable trade against the #31-regression risk in `MapViewRepresentable`.
- `@designer` review pass (spec §8 step 2, sign-plate legibility, color-legend fidelity, banner CTA feel) — not done yet, correctly sequenced as next-in-lifecycle per the PR description, not a QA gate.
- Localization, quiz mini-game, borough-specific pricing, push nudges, video sign walkthrough, analytics — all explicitly punted per spec §12, correctly out of scope here.

## Smoke tests run

- **Build:** `xcodebuild clean build -configuration Debug` on the worktree, my own dedicated simulator (`qa-ft12`, `92F25F27-AA7C-49F0-8D7A-87B12681F59E`, iPhone 17 Pro / iOS 26.5) — `** BUILD SUCCEEDED **`.
- **Full test suite:** `xcodebuild test` on the same simulator — `** TEST SUCCEEDED **`, 532 passed / 0 failed. Independently grepped the full result log for `passed on '.../failed on '` counts and cross-checked FT12-specific suite names/method counts (see Finding #3).
- **Isolation check:** `git diff --stat $(git merge-base main ios/ft12-parking-guide)..ios/ft12-parking-guide` — exactly the 13 files claimed (`ContentView.swift`, `Constants.swift`, `FAQHelpView.swift`, `SettingsView.swift`, 6 new `ParkingGuide/*.swift`, `FT12Tests.swift`, `docs/parking-101-content.md`). No `LocationService.swift`, no `MapViewRepresentable.swift`, no PWA/`supabase/**`/`tiles/**` files touched.
- **Live-UI smoke — fresh install, first-launch banner:** Erased/never-launched-before install on my dedicated sim. Launched, screenshotted within ~1s (before the auto-hide timer could plausibly fire) — banner rendered correctly: "New to NYC parking? Free parking is doable — read the guide" with signpost icon, chevron, and X, sitting in a `.regularMaterial` rounded card above the map, map/toolbar/ASP banner all intact and unobstructed. Follow-up screenshots at ~1s intervals confirmed the banner gone by ~7-8s post-launch — consistent with the documented `~8s` auto-hide `.task`.
- **Live-UI smoke — persistence gate:** Read the on-disk `.plist` at the app's container path directly (`Library/Preferences/com.kevinhoxha.wepark.plist`) — confirmed `wepark_parking101_prompt_shown = true` was persisted after the auto-hide fired. (Note: `simctl spawn <udid> defaults read <bundle-id>` does **not** work reliably against sandboxed app containers on this simulator/runtime — reading the plist file directly via `get_app_container ... data` was the reliable method; worth remembering for future QA passes.)
- **Live-UI smoke — one-shot behavior:** Terminated and relaunched the app (no erase) — banner did not reappear; map/toolbar/ASP banner rendered normally.
- **Live-UI smoke — Dark Mode + large Dynamic Type (banner only):** `simctl ui ... appearance dark` + `content_size extra-extra-extra-large`, fresh install again. Banner correctly dark-adapted (`.regularMaterial` reads as a dark card), text scaled and wrapped cleanly to two lines with zero truncation/clipping, map base tiles rendered in dark mode, toolbar buttons dark-adapted. **This exercises `ParkingGuidePromptBanner` only, not `SignPlateView`/`ParkingGuideView`'s dark-mode/Dynamic-Type behavior** — that part relies on code review (§5/§11 compliance confirmed by reading `SignPlateView.swift`'s hardcoded `Color.white` + `.dynamicTypeSize` cap) rather than a live screenshot. Flagged explicitly as not verified in Finding #2/#4.
- **Interactive navigation (Settings → Parking 101, FAQ cross-link):** **Attempted, not achieved** — see Finding #2. Two calibrated `osascript`/System Events coordinate clicks at the gear icon both missed (landed on the map, confirmed via before/after screenshots showing no state change). No `idb`/`cliclick` available in this sandbox. Fell back to the code-level + shared-constructor evidence described in Finding #2.
- **Simulator hygiene:** created `qa-ft12` (`92F25F27-AA7C-49F0-8D7A-87B12681F59E`) fresh for this session, never touched `F0820726-...` or the other agent's `F1FEB44A-...`/`F0820726-...` sims observed running concurrently (confirmed via `ps aux` mid-session — another agent's `xcodebuild test` process was independently running against `F0820726-...` at the same time, untouched by me). Deleted `qa-ft12` at the end of the session — confirmed gone from `simctl list devices`.

## What's working

- The isolation discipline is real, not just claimed: the ContentView diff is genuinely confined to the banner-mount site, one `ActiveSheet` case, and a two-line guard in `handleMapTap`. This PR will rebase over TF2-16 without friction.
- The money-math pipeline is exactly as auditable as the spec wanted: every dollar figure traces to a named, sourced, dated `MoneyMathConstants` value, the annual figure is a live computed property (not a literal), and `MoneyMathConstantsTests` locks in both the 12× relationship and the exact spec-cited numbers. Zero copy/constant drift risk here.
- The Color Legend is a clean, correct reuse of `ParkingColors` — no shadow palette, no drift from `docs/design/ios-mvp-palette.md`, and the 6h-threshold framing is copied almost word-for-word from the source doc.
- `SignPlateView`'s no-invented-icons rule is honestly followed — I read every plate instantiation in `SignSchoolSectionView.swift` and confirmed the broom/hydrant SF Symbols are all on section headers, never on a plate face, and every plate carries a non-empty, content-accurate `.accessibilityLabel`.
- The first-launch banner is a genuinely pleasant, non-intrusive implementation — the map is never obstructed, even at accessibility-XXL Dynamic Type in Dark Mode, and the mutual-exclusivity logic with the Drive Mode card / Park Until pill is structurally sound (same three-state `bottomSafeAreaContent` branch that already exists for those two).
- Test coverage is well-targeted for a static-content feature — the gate tests mirror `BackgroundNoteGate` faithfully, the money-math tests actually guard the auditability claim (not just "value is positive"), and the `ActiveSheet` id-collision test is a nice touch that would have caught a real bug if one existed.

## Pass 2 (2026-07-09)

**Reviewed:** PR #65, branch `ios/ft12-parking-guide` at `ef3969d` (fix commit on top of pass-1's `1ec4f05`), scoped to the fix for pass-1 Finding #1 only.
**Verdict:** ✅ SHIP CLEAN (Finding #1 closed; pass-1's #2/#4/#5 remain open, correctly deferred to Kevin's on-device pass)

### Finding #1 — verified closed

Read `git show ef3969d` directly (not the PR narrative). The commit touches exactly two files — `docs/parking-101-content.md` and `SignSchoolSectionView.swift` — and nothing else; confirmed via `git diff --stat 893cf51..ef3969d` that the branch's full 13-file footprint from pass-1 is unchanged (the fix commit adds zero new files, touches zero other files).

The corrected 3-tier ladder now reads:

| Sign | You may... | You may NOT... |
|---|---|---|
| **NO PARKING** | Stop to actively load or unload passengers **or merchandise** | Leave the car parked, or idle with no active loading/unloading happening |
| **NO STANDING** | Stop to actively pick up or drop off **passengers only** — no merchandise | Load or unload cargo, or remain in the car for any other reason |
| **NO STOPPING** | Nothing, except to obey a traffic signal, sign, or a police officer | Stop for any other reason, not even to drop someone off |

Checked against real VTL semantics (§129-a "Parking" vs §129-b "Standing" vs §129-c "Stopping"):
- **No Parking** — passengers or merchandise loading/unloading, correctly stated as the distinguishing allowance vs. No Standing. The "leave the car parked, or idle with no active loading/unloading happening" framing for the NOT-allowed side is slightly stricter-sounding than the letter of the law (the statute's actual test is temporary/expeditious loading-or-unloading activity, not continuous physical motion every second), but for a beginner's guide this is a safe, non-misleading simplification — it correctly steers a novice away from the old bug (thinking "driver stays in car" alone was sufficient) without introducing a new misconception. No residual inaccuracy that would cause a ticket if followed.
- **No Standing** — passengers only, no merchandise, correctly stated and now explicitly parallel to the No Parking row (same "Stop to actively..." verb structure), which is exactly the pass-1 ask: make the two rows legible as a matched pair differing only in cargo eligibility.
- **No Stopping** — "nothing, except to obey a traffic signal, sign, or a police officer" is the correct VTL §129-c framing (this row wasn't part of Finding #1, but the fix commit tightened its wording too, in the same spirit — checked it for regressions and found none; it remains accurate).

The new intro paragraph (both in the doc and the SwiftUI `Text`) now states the actual legal test up front — "the actual legal test between the first two tiers is what you're allowed to load: No Parking permits passengers or merchandise; No Standing permits passengers only, never cargo. That's the real difference, not whether the driver stays in the car" — which directly names and corrects the exact misconception pass-1 flagged. No ambiguity or residual ladder-copy issue found. Finding #1 is closed.

### Doc/view consistency and scope check

- `docs/parking-101-content.md` (lines 56-66) and `SignSchoolSectionView.swift` (lines 66-96, both the intro `Text` and all three `ladderRow` calls) carry matching language — same three-part legal-test framing, same "actively load/unload" verb, same "no merchandise"/"or merchandise" parallel structure in both places. No doc-vs-view drift.
- Diffed the fix commit line-by-line (`git show ef3969d`): confirmed no other section (Pitch, Metered, Hydrant, Arrows, Combined Stacks, ASP) was touched, no test file was touched, no `ContentView.swift`/`Constants.swift`/`SettingsView.swift`/`FAQHelpView.swift` touched. Scope is exactly Finding #1 (plus the Finding #3 test-count fix, done separately in the PR body, not this commit).

### Plate faces — untouched, confirmed by direct read

Read the full current `SignSchoolSectionView.swift` (not just the diff). Every `SignPlateView` instance across all six subsections (ASP, ladder, Metered, Hydrant [no plate], Arrows, Combined Stacks) still renders only real sign wording on the plate `lines:` — "NO PARKING," "NO STANDING," "NO STOPPING," "PAY TO PARK," dates/times, "STREET CLEANING," a directional arrow glyph. None of the new merchandise/passenger caption language leaked onto a plate face; it lives exclusively in the `allowed`/`notAllowed` caption strings and the intro paragraph, both of which render outside `SignPlateView`. AC-4 (plate-face purity) remains intact after the fix.

### Tests

Ran on my own dedicated simulator (`qa-ft12-p2`, freshly created, deleted at end of session — never touched the shared `F0820726-...` sim, which I confirmed stayed `Shutdown` throughout):

- `xcodebuild test -only-testing:` the four FT-12 test suites (`ParkingGuidePromptGateTests`, `MoneyMathConstantsTests`, `ParkingGuideSectionTests`, `ParkingGuideActiveSheetTests`) — **17/17 passed**, matching the builder's claimed FT-12 target exactly.
- `xcodebuild test` full suite — **533 passed / 0 failed** (`xcresulttool get test-results summary` gives an authoritative `"totalTestCount": 533, "failedTests": 0, "result": "Passed"`). This is **one higher** than the builder's claimed 532 in both the fix commit message and the PR body. Not investigated further — it does not change the verdict (more passing tests, zero failures, no regression signal), and this repo has a documented history of off-by-one test-count arithmetic in PR descriptions (pass-1 Finding #3, and the pre-existing FT10Tests note in `docs/field-testing-log.md`). Flagging as a fresh minor nit rather than blocking: **the builder should recount programmatically rather than trusting the prior PR description's math**, since 532 was itself a "corrected" figure from pass-1 and drifted again.

### PR body

`gh pr view 65` confirms: Test plan section states "532 passed, 0 failed... 17 new FT-12 test methods" (matches pass-1 Finding #3's correction) and a dedicated `## QA pass 1 fix (2026-07-09)` section exists, correctly summarizing Finding #1's fix, Finding #3's fix, and explicitly acknowledging Findings #2/#4/#5 as deferred to Kevin's on-device pass (not silently dropped). Body is accurate against what the fix commit actually contains — no narrative drift found.

### New findings this pass

- 🟢 **#6 (nit): full-suite count drifted again — 533 actual vs. 532 claimed in both the commit message and the PR body.** Same class of issue as pass-1 Finding #3. Not blocking. Owner: `@ios-engineer` — recount programmatically before writing commit messages/PR bodies, don't carry forward a prior pass's number without re-verifying.

### Verdict

**SHIP CLEAN.** Finding #1 (the only blocking-for-content-accuracy item from pass-1) is correctly and precisely fixed in both the doc and the view, in sync, with no scope creep and no plate-face regression. FT-12 tests 17/17, full suite 533/0 (builder said 532/0 — trivial, non-blocking recount nit, logged as #6). Pass-1's remaining open items are unchanged and correctly still owned by Kevin's on-device pass, not this fix:

- **#2** — interactive Settings → Parking 101 tap-through, still not live-verified (same sandbox limitation as pass-1; not re-attempted this pass since it's out of scope for a Finding-#1-only re-review).
- **#4** — `SignPlateView` 120pt fixed-width frame at `.accessibility3` Dynamic Type, still not live-verified.
- **#5** — AC-12 screenshot artifacts still not embedded in the PR body (cosmetic, future-PR habit fix).

None of these three block ship; they were already correctly scoped to Kevin's on-device pass in pass-1 and remain so.
