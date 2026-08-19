# FT-20 Stream A (Bottom Sheet Container) QA Pass 1 — 2026-08-19

**Reviewed:** branch `ios/ft20-stream-a-sheet-container` at `807770b5`, against
`docs/ft20-bottom-sheet-navigation-spec.md` §4.1/§4.2/§5.1/§9, `docs/design/ft20-bottom-sheet-review.md`
findings B1/B2/S1.
**Environment:** Linux VPS — no Xcode, no simulator, no `xcodebuild`. This is a static code read; nothing
below is a compile or runtime claim. Kevin verifies compile/test status and live-UI smoke on his Mac.
**Verdict:** 🔴 **DO NOT MERGE STANDALONE TO `main`.** The container/detent-math work itself (Priorities 2–4)
is solid and well-reasoned. But the mechanical "dismiss → `.browseNav`" change, applied correctly and
exhaustively across every existing `ActiveSheet` case, has a consequence the PR's own doc comments claim
doesn't exist: it makes `.browseNav` reachable **today**, through every ordinary sheet dismissal in the
app — not "unreachable until Stream C lands" as the code claims. See Finding #1. This is a code-review-
catchable regression, not a hypothetical.

## Summary

Stream A's actual deliverable — `BrowseNavigationSheet.swift`'s custom-detent math, the S1-conformant
3-item list, and the `ActiveSheet.browseNav` case itself — is good work: B1 (never system `.medium`) and
B2 (measured heights, clamped below `.large`) are both genuinely satisfied, not just claimed, and the
`@ScaledMetric`-constrained-frame trick for the greedy `List` is the right fix for OQ-3's "no more than
three rows" promise. The problem is architectural, not local: this PR's mechanical dismiss-target rewrite
(§4.1's own description — "a small, mechanical, but real diff across every sheet case") converts `nil`
to `.browseNav` at literally every existing sheet-dismiss site in `ContentView.swift`, and nothing in this
PR gates that. The result: merged alone, the very first time *any* existing sheet in the shipped app is
dismissed outside Drive Mode or block-select (Settings, ParkConfirmView Cancel, ParkedCarDetailView
dismiss, ParkUntilSheet skip, ReportSheet dismiss, BlockDetailView dismiss, the Parking-101 Done button —
all of them), the user gets trapped behind a new, `interactiveDismissDisabled(true)`, un-swipeable stub
sheet ("Search for a destination" placeholder text + Settings/Cruise/Parking-101 rows) with no way back to
a plain map view for the rest of the session short of force-quitting. Two existing, still-live Drive-Mode
entry points (the old combined-menu's "Drive to a destination," and the in-Drive "Park here" button) also
silently start no-op'ing the first time this happens, because their `guard activeSheet == nil` checks were
not swept the same way `enterCruiseMode()`'s was. None of this is a missed dismiss site — every one of the
14 case-dismiss closures + 3 auxiliary functions is *correctly* wired per the end-state spec. The bug is
sequencing: this is end-state behavior landing without the Stream C wiring (Drive-Mode-entry force-hide,
cold-launch mount) that's supposed to make it safe.

## Acceptance criteria checklist

Per the task brief, most of §7's ACs are Stream B/C territory and untestable until those land. Marking
Stream A's actual scope:

- [x] AC-2 (never interactively dismissible to nothing) — `.interactiveDismissDisabled(true)` present on
  `.browseNav`'s presentation, `ContentView.swift:1210`. Verified by inspection.
- [~] AC-1, AC-3, AC-6 (3 detents / peek default / drag-snap) — container code is correct in isolation but
  **not actually reachable as a real entry point yet** (Stream C's job); can't be verified as "the browse
  sheet always shows" because nothing mounts it at cold launch. Partial credit only.
- [ ] AC-4, AC-5 (search visible at every detent / tap-to-expand) — Stream A ships `BrowseSheetSearchAreaStub`,
  a static non-interactive placeholder. AC-5 (focus-on-tap) is explicitly Stream B. **Deferred to B.**
- [ ] AC-7 through AC-14 (search/place/Go) — **Deferred to Stream B entirely**, not in this PR's diff.
- [x] AC-15 (medium list shows exactly Settings/Cruise/Parking 101, no menu) — `BrowseNavigationSheet.swift:260–287`.
- [x] AC-16 (Settings opens `.settings` unchanged) — `ContentView.swift:1192`, `onSettingsTapped: { activeSheet = .settings }`.
- [x] AC-17 (Parking 101 opens `.parkingGuide` unchanged) — `ContentView.swift:1194`.
- [x] AC-18 (Cruise calls `enterCruiseMode()` directly, no menu) — `ContentView.swift:1193`; guard fixed at
  `2037–2038`. **But see Finding #2** — the equivalent old entry points were not sViewpt the same way, so
  AC-18's *spirit* (no silent no-op) is violated elsewhere in the same commit.
- [ ] AC-19 through AC-33 (removed/relocated chrome, FT-15 boundary, Drive Mode boundary, non-goals) —
  **Deferred to Stream C** (gear/menu deletion, Park Until relocation, `driveModeActive`/`blockSelectModeActive`
  force-hide wiring). Confirmed by inspection: Stream A makes zero changes to `MapViewRepresentable.swift`,
  `recenterDriveMode()`, `endDriveControl`, or `recenterRow` (AC-30's zero-touch guarantee holds).
- [~] AC-34 (VoiceOver grabber) — system `.sheet`/`.presentationDragIndicator` gives this for free under
  Option A; not independently re-verifiable without a device.
- [x] AC-35 (accessibility labels ported) — `"Open settings"` / `"Parking 101 guide"` in the new list rows
  (`BrowseNavigationSheet.swift:266`, `282`) match `gearButtonOverlay`'s existing labels verbatim
  (`ContentView.swift:1487`, `1506`) exactly. Cruise's hint is newly authored (no old per-item hint existed
  to port — the old combined menu only had one hint on the whole `Menu`), acceptable given S1 is new UI.

## Findings

### 🔴 Blocking

**#1 — `.browseNav` is claimed "unreachable until Stream C lands" but is actually reached by every ordinary
sheet dismissal in the app today. Merging this branch alone traps users behind an inescapable, half-built
sheet.**
- **Where:** `ContentView.swift:330–334` (the false claim, in the `activeSheet` doc comment) vs. the
  mechanism that contradicts it: `dismissTargetOutsideBrowseNav` (`ContentView.swift:863–865`, `(driveModeActive
  || blockSelectModeActive) ? nil : .browseNav`), applied at all 14 case-dismiss closures (e.g.
  `ContentView.swift:900`, `904`, `923`, `926`, `950`, `1002`, `1010`, `1034`, `1069`, `1096`, `1131`, `1147`,
  `1161`, `1224`) plus `dismissBlockDetail()` (`2758` region), `handleLongPress` (`2977`), `initiatePathBPinDrop`
  (`2994`); and the top-level `.sheet(item:, onDismiss:)` backstop (`ContentView.swift:714–738`), which sets
  `activeSheet = .browseNav` for the cases with no explicit dismiss closure of their own (`.settings`) and
  for any interactive swipe-dismiss.
- **What:** Before this PR, every one of these dismiss paths set `activeSheet = nil` — dismiss a sheet,
  see the map. After this PR, every one of them sets `activeSheet = .browseNav` (as long as
  `driveModeActive`/`blockSelectModeActive` are both false, which is the overwhelmingly common case in
  normal browse-mode use). `.browseNav`'s presentation has `.interactiveDismissDisabled(true)`
  (`ContentView.swift:1210`) by design (§4.1: "Apple Maps' sheet is never fully dismissible") — so once it
  first appears, there is no swipe-to-dismiss, and nothing in this PR (Stream C hasn't landed) ever clears
  it back to `nil`. The only two escapes — Drive Mode entry and block-select entry — force it to `nil`
  *temporarily*, but the moment that mode ends and the user dismisses anything else, the exact same
  mechanism re-triggers it. The only real escape is a cold relaunch (`activeSheet` defaults to `nil` at
  init).
- **Repro (by code trace, not yet device-verified):** Long-press the map → "Park my car here" →
  `ParkConfirmView` appears → tap Cancel. `onCancel` (`ContentView.swift:903–905`) sets
  `activeSheet = dismissTargetOutsideBrowseNav`, which resolves to `.browseNav`. The user, who just wanted
  to dismiss a confirm sheet and see the map again, instead gets a brand-new, non-removable sheet showing
  a non-functional "Search for a destination" placeholder row and a Settings/Cruise/Parking-101 list,
  permanently, for the rest of the app session. Equally reachable via: opening Settings from the gear icon
  and swiping it away; tapping "Skip" in `ParkUntilSheet`; tapping "Done" on the Parking 101 guide; tapping
  a community pin and dismissing `PinDetailSheet`; tapping a block and dismissing `BlockDetailView`. This is
  not an edge case — it is the first thing that happens on the first ordinary dismiss in the app.
- **Why it matters:** This is exactly the class of bug this project's own history singles out —
  W8.5c-polish shipped 210/0 passing tests with the entire toolbar layer silently broken in the live app,
  caught only by Kevin's on-device smoke. This PR is `[COMPILE-UNVERIFIED]` and has no live-UI smoke yet;
  if Kevin's Mac build passes compile and he does even the most basic smoke (open the app, drop a pin,
  cancel it), he will hit this immediately. Per `HANDOFF.md`'s own precedent, FT-15/W8.5b/etc. streams are
  merged to `main` individually and sequentially — this is not a "will get fixed by Stream C before anyone
  sees it" situation unless that's made an explicit, enforced condition of merge.
- **Fix options (naming, not prescribing — QA doesn't fix):** (a) hold this branch and land it merged
  together with Stream C's Drive-Mode/block-select force-hide + cold-launch mount in one PR, so
  `.browseNav` is never reachable without the safety net that's supposed to accompany it; or (b) add an
  explicit gate (e.g. a `browseNavRolloutEnabled` flag, default `false`) so `dismissTargetOutsideBrowseNav`
  and the backstop fall back to literal `nil` until Stream C flips it — making the doc comment's claim
  actually true instead of aspirational.

**#2 — Two existing, still-live Drive-Mode entry points retain the exact stale `activeSheet == nil` guard
that `enterCruiseMode()` was explicitly fixed for, and will silently no-op as a direct consequence of
Finding #1.**
- **Where:** `ContentView.swift:1759` (`driveEntryButton`'s "Drive to a destination" menu item — still live,
  not yet deleted, that's Stream C's job) and `ContentView.swift:1912` (the in-Drive "Park here" button,
  visible whenever `driveModeActive == true`).
- **What:** The commit's own stated fix was: *"enterCruiseMode()'s activeSheet == nil guard... would
  otherwise silently no-op every tap on the new sheet's own Cruise row"* — correctly fixed via
  `noBlockingSheetPresented` (`ContentView.swift:2037–2038`). But the identical guard pattern was not swept
  at these two other call sites, which are functionally identical in kind (an entry action gated on "no
  sheet is currently blocking"). Once Finding #1 fires and `activeSheet` becomes `.browseNav` (non-nil),
  **both of these silently stop working**: tapping "Drive to a destination" from the old combined menu does
  nothing (`showDriveModeDestination` never flips true), and tapping "Park here" mid-drive does nothing (no
  error, no feedback — the driver just can't drop a pin). The in-Drive case is the more serious of the two:
  it's a core, safety-relevant action (recording where you parked) silently failing with zero user-visible
  signal.
- **Why it matters:** This is precisely the class of guard-staleness bug the task briefing asked to be
  checked for by name ("the same stale-guard pattern doesn't exist elsewhere for Settings or Parking 101")
  — the actual instances found are in different call sites than named, but are the same bug class, and are
  live production code today (not dead code Stream C will delete before anyone sees it — Stream C hasn't
  landed).
- **Repro:** Trigger Finding #1's repro first (any sheet dismiss outside Drive Mode) so `activeSheet ==
  .browseNav`. Then tap the toolbar's combined drive-entry Menu → "Drive to a destination." Nothing
  happens. Separately: enter Drive Mode via Cruise (still works, since that path doesn't check the stale
  guard), then trigger `activeSheet = .browseNav` isn't directly possible mid-drive since
  `dismissTargetOutsideBrowseNav` resolves to `nil` while `driveModeActive == true` — **except** if
  `.browseNav` was already set *before* Drive Mode started (the common case, per Finding #1) and nothing
  clears it on Drive Mode entry (that's Stream C's job), it persists into the drive session, so "Park here"
  no-ops for that entire session.
- **Fix:** Same fix as Finding #1 resolves this automatically — if `.browseNav` genuinely can't be reached
  before Stream C lands, these two guards never see anything but `nil` and are unaffected. If Finding #1 is
  fixed by an explicit `noBlockingSheetPresented`-style sweep instead, these two sites need the same
  treatment `enterCruiseMode()` got.

### 🟡 Significant

**#3 — `listSectionChromeAllowance = 24` is a guess, self-flagged by the engineer as
`[COMPILE-UNVERIFIED / NEEDS ON-DEVICE CHECK]`, and is plausibly too small for `.insetGrouped`'s real
top+bottom section inset.**
- **Where:** `Views/BrowseNavigationSheet.swift:68–78`.
- **What:** `.insetGrouped` List sections in UIKit/SwiftUI commonly carry more combined top+bottom
  whitespace than 24pt (real-world values are often closer to 35–50pt total depending on iOS version and
  whether a header/footer is present — this list has neither). If the real number is meaningfully larger,
  `actionListHeight` under-reports the true rendered height, and the medium detent will either clip the
  3rd row or force an internal scroll — precisely the "and no more" promise (OQ-3) this whole mechanism
  exists to protect.
- **Why it matters:** This is exactly the failure mode design-review finding B2 was written to prevent, and
  it's the one constant in `BrowseSheetDetentMath` that cannot be pinned by a unit test (it's a physical
  UIKit layout constant, not derivable logic) — it can only be confirmed on-device.
- **Note:** The engineer already disclosed this honestly rather than hiding it — this is not a hidden
  defect, it's an open item that needs Kevin's on-device confirmation before this is trustworthy. Elevating
  it here so it isn't lost among the green checkmarks: **explicitly check the 3rd row (Parking 101) isn't
  clipped and there's no dead space below it, at default Dynamic Type, before signing off.**

**#4 — `browseSheetDetentSelectionBinding`'s classification logic and `BrowseSheetDetentKind`'s
remeasurement-safety design have zero test coverage — the highest-conceptual-risk piece of the detent
system is entirely unverified.**
- **Where:** `Views/BrowseNavigationSheet.swift:118–143`; no corresponding tests in `FT20StreamATests.swift`.
- **What:** `FT20StreamATests.swift` covers `BrowseSheetDetentMath`'s pure peek/medium arithmetic well (5
  solid tests + a good B1-regression pin), but the actual detent-*selection* binding — the get/set logic
  that decides which semantic `BrowseSheetDetentKind` a raw `PresentationDetent` maps to, and vice versa —
  has no tests at all, despite being ordinary Swift logic that doesn't require SwiftUI rendering to unit
  test (it operates on `PresentationDetent`/`CGFloat` values, not views). Untested branches: the `set`
  closure's three-way branch (`.large` / exact match to `mediumHeight` / else-defaults-to-`.peek`), and
  specifically what happens if a reported `newValue` doesn't exactly equal either `.height(peekHeight)` or
  `.height(mediumHeight)` (e.g. a remeasurement lands between get and set) — it silently falls into
  `.peek`, which could misclassify a user's medium-detent drag as peek.
- **Why it matters:** This is pure Swift, not UIKit-bound — there's no excuse tied to "no simulator on this
  machine" for skipping it the way there is for the `List`-rendering-dependent chrome allowance (#3). It's
  also the piece design-review B2 was most worried about (raw-`PresentationDetent`-goes-stale-on-remeasure)
  — the mitigation is architecturally sound but its correctness rests entirely on manual reasoning, not a
  test that would catch a regression.
- **Fix:** Add unit tests for `browseSheetDetentSelectionBinding`'s get/set round-trip, including the
  edge case of a `newValue` that doesn't exactly match either custom height.

### 🟢 Minor / nit

**#5 — `Self.maxAllowedMediumHeight` reads `UIScreen.main.bounds.height`, a deprecated-direction API
(Apple's guidance since iOS 13 is per-`UIWindowScene` sizing, not `UIScreen.main`).**
`BrowseNavigationSheet.swift:313–315`. Not wrong today (still works, and this project has other unaudited
`UIScreen.main` precedent-free zones), but worth a note since design-review B2's whole point is Dynamic-Type
/ device-size robustness — `UIScreen.main` can misreport on scenes not on the main screen. Low priority;
this app is single-window/single-scene.

**#6 — Commit message says "13 case-dismiss closures"; actual count by inspection is 14** (`parkConfirm`
×2, `parkedCarDetail` ×2, `notificationRationale` ×1, `parkUntil` ×2, `pinDetail` ×1, `reportPin` ×1,
`signCheckConfirm` ×1, `arrivalPrompt` ×2, `parkingGuide` ×1, `blockRestrictionReport` ×1). Cosmetic —
doesn't affect correctness, and nothing was actually missed (see Findings #1/#2, which are about the
*consequence* of universal coverage, not a gap in it).

**#7 — `.browseNav`'s presentation omits `.presentationBackground(...)`, unlike all 11 other
`.presentationDetents` call sites in the file, which explicitly set `.regularMaterial` or
`.ultraThickMaterial`.** `ContentView.swift:1198–1210`. Not a bug — the spec's own §4.1 code sample also
omits it, and a translucent system-default sheet background is arguably *more* correct here given
`.presentationBackgroundInteraction` is meant to let the map show through — but it's an inconsistency with
the rest of the file's established convention worth a one-line comment explaining it's deliberate, so a
future reader doesn't "fix" it by adding `.regularMaterial` and breaking the see-through map interaction.

### 💡 Out of scope (logged, not fixed)

- AC-7–14 (search/place/Go), AC-19–22 (chrome removal/Park Until relocation), AC-23–27 (FT-15 boundary
  wiring), AC-28–31 (Drive Mode boundary wiring) — all correctly Stream B/C scope, not evaluated as
  failures here.
- Real Dynamic Type / AX3 on-device verification of the peek and medium heights (design-review B2's own
  ask) — cannot be done on this Linux VPS; flagged for Kevin's Mac smoke.
- Sunlight legibility of the sheet chrome (S6) — explicitly a Kevin-smoke item, not a code review item.

## Spec-accuracy items (engineer-flagged, both confirmed correct by inspection)

1. **`.onGeometryChange` is iOS 17+, not iOS 16+ as spec §4.1 states.** Confirmed:
   `IPHONEOS_DEPLOYMENT_TARGET = 17.0` throughout `project.pbxproj`, and `.onGeometryChange` is documented
   Apple API introduced in iOS 17 — the spec's "iOS 16+" framing for the measurement mechanism is wrong.
   Recommend correcting the spec text.
2. **Spec §4.1 misattributes where the `nil`-assignment lived pre-PR.** The spec cites
   `"ContentView.swift:671–678's .sheet(item: $activeSheet, onDismiss: { activeSheet = nil })"` as the
   place all ~12 cases' dismiss logic lived. Confirmed by diffing against the pre-PR commit
   (`HEAD~1:ios/WePark/WePark/ContentView.swift:683–691`): the top-level `.sheet(item:, onDismiss:)`
   closure never set `activeSheet = nil` — it only cleared `selectedSegmentID`/`selectedBlockKeys`. The
   `nil` assignment lived in each *case's own* dismiss closure (`onCancel: { activeSheet = nil }`, etc.),
   which is what this PR actually had to change at each site. Recommend correcting the spec's citation.

## Smoke tests run

No live-UI smoke possible (Linux VPS, no simulator/Xcode). All verification below is static code reading
and cross-referencing against the pre-PR commit (`HEAD~1`) and the design-review doc:

- Enumerated all 13 pre-existing `ActiveSheet` cases + the new `.browseNav` case; traced every
  `activeSheet =` assignment in `ContentView.swift` (48 occurrences via `grep`) and classified each as
  entry / dismiss / transition. Confirmed zero cases silently retain a raw `nil` dismiss outside the one
  documented, correct exception (`enterBlockSelectMode()`).
- Diffed `dismissTargetOutsideBrowseNav`/`noBlockingSheetPresented` against every call site that reads
  them; traced the top-level `.sheet(item:, onDismiss:)` backstop's guard logic and reasoned through the
  item-to-item vs. item-to-nil SwiftUI dismiss-callback distinction, cross-checked against this file's own
  pre-existing, already-shipped `blockDetail → pinDetail` transition precedent to confirm the guard can't
  double-assign or stomp an in-flight transition.
- Read `BrowseSheetDetentMath` and all 9 tests in `FT20StreamATests.swift` line by line; confirmed the
  clamp ceiling (`UIScreen.main.bounds.height * 0.75`) is meaningfully below `.large` (~90%), so a clamped
  medium detent is never visually indistinguishable from large.
- Compared `BrowseNavigationSheet.actionList`'s `List`/`Section`/`.listStyle(.insetGrouped)`/`Label`
  anatomy against `DriveModeDestinationView.swift:269–302`'s `recentDestinationsList` line by line —
  confirmed S1 conformance (no capsule/pill FT-18-style rows).
  confirmed `enterCruiseMode()`'s fixed guard (`ContentView.swift:2037–2038`) and traced the two remaining
  stale `activeSheet == nil` guards (`1759`, `1912`) that weren't part of the same sweep (Finding #2).
- Verified `IPHONEOS_DEPLOYMENT_TARGET = 17.0` in `project.pbxproj` to confirm the engineer's
  `.onGeometryChange` iOS-version spec-accuracy claim.
- Diffed against `HEAD~1` to confirm the spec's `ContentView.swift:671–678` citation for the old
  `nil`-assignment location is inaccurate (the assignment lived per-case, not in the shared `onDismiss`).
- Checked for `let`-with-default-value structs (the known Swift memberwise-init pitfall this project has
  hit before) — none found in the new file; `BrowseNavigationSheet` and `BrowseSheetSearchAreaStub` are
  both safe (explicit custom init or no stored properties).

## What's working

- **The detent math is genuinely good, careful work.** `BrowseSheetDetentMath` correctly implements both
  B1 (never system `.medium` — confirmed nowhere in the diff does `.browseNav`'s config reference `.medium`)
  and B2 (measured, not hardcoded, with a clamp that's meaningfully below `.large`). The peek floor (44pt +
  grabber) and the growth-with-content behavior are both correctly reasoned and covered by real tests, not
  tautologies — `testPeekHeight_growsWithLargerMeasuredContent` and the B1-regression pin
  (`testMediumHeight_realisticContentIsFarShorterThanSystemMediumFraction`) are exactly the tests you'd
  want to catch the two design-review Blocking findings regressing.
- **The `@ScaledMetric`-plus-explicit-frame fix for `List`'s greedy sizing is the right call**, correctly
  reasoned in its own doc comment (`BrowseNavigationSheet.swift:206–228`) — this is a real, non-obvious
  SwiftUI gotcha (a `List` inside a system sheet lays out against the full `.large` container regardless of
  the visible detent) and the fix directly protects OQ-3's "search + exactly three rows and no more"
  promise, which is the one thing Kevin explicitly asked for by name.
- **S1 conformance is exact, not approximate** — `List` + `Section` + `.listStyle(.insetGrouped)` +
  SF-Symbol-via-`Label`, matching `recentDestinationsList`'s anatomy, correctly avoiding FT-18's
  capsule/pill language per the design review's explicit instruction.
- **The dismiss-target mechanical sweep itself is exhaustive and correct relative to the end-state spec** —
  this is worth saying plainly since it's easy to read Finding #1 as "the sweep was wrong." It wasn't. Every
  site was converted correctly and consistently; the problem is that correct, universal coverage of an
  end-state behavior is exactly what makes it dangerous to ship before the state that's supposed to contain
  it (Stream C) exists.
- **The two flagged spec inaccuracies are real and worth fixing** — good calibration from the engineer to
  flag rather than silently work around them.
