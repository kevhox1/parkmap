# TF2-20 Diagnosis — Bowery "mostly green" on build 1.0(14)

**Diagnosed by:** ios-engineer, 2026-07-12, isolated worktree.
**Scratch test:** `ios/WePark/WeParkTests/TF220DiagnosticTests.swift` (commit `999aaef` on
`worktree-agent-af41044cdfdb7c154`, not merged — scratch only, safe to delete once this
ticket is closed).
**Verdict: NOT A BUG.** The app, tile data, decoder, engine, bundle, and render/overlay
pipeline are all correct. The apparent discrepancy is fully explained by a **day-of-week
mislabel in the bug report itself**: 2026-07-12 is a Gregorian-calendar **Sunday**, not a
Saturday. Bowery's dominant restrictions are explicitly "EXCEPT SUNDAY," so a green-heavy
map at that moment is the *correct* rendering, not a defect.

---

## TL;DR

| Date evaluated | Day-of-week (real) | Real decoder + real engine + real tile data tally |
|---|---|---|
| 2026-07-11 17:00 ET (**the real Saturday**) | Saturday | **67 RED / 22 AMBER / 14 GREEN** |
| 2026-07-12 17:00 ET (labeled "Sat" in the field-testing-log; **actually a Sunday**) | Sunday | **18 RED / 0 AMBER / 85 GREEN** |

The 67/22/14 baseline the field-testing-log cited as "what the data says" is **exactly**
reproduced by this diagnostic's real-decoder/real-engine/real-tile-data harness — but only
when evaluated on the actual Saturday (2026-07-11). When evaluated on the actual date Kevin
was using the app (2026-07-12), which is a Sunday, the harness produces 18/0/85 — a
green-dominant map, matching what Kevin saw ("almost all of Bowery renders green").

There is no code path in `TileLoader`, `Segment`/`ParkingRule` decode, `ParkingRulesEngine`,
or the `ContentView`/`MapViewRepresentable` overlay pipeline that needed to change. The app
was showing the objectively correct state for a Sunday afternoon.

---

## Evidence, step by step (per the dispatched diagnostic plan)

### Step 1 — Real decoder + real engine + real data at the real time

Found the 8 tile files containing `street == "BOWERY"` segments by scanning
`tiles/*.json` for `"street": "BOWERY"` (103 segments total, matching the 67+22+14=103
figure in the field-testing-log):

```
tile_10_12.json (21)  tile_11_12.json (17)  tile_6_10.json (16)  tile_6_9.json (2)
tile_7_10.json (16)   tile_7_11.json (3)    tile_8_11.json (17)  tile_9_11.json (11)
```

None of these are among the 8 *new* tile files regen 6 added (`tile_1_13`, `tile_1_14`,
`tile_2_13`, `tile_2_14`, `tile_20_22`, `tile_25_27`, `tile_26_7`, `tile_40_25`) — Bowery
segments were not resegmented into new tiles by regen 6.

Wrote `ios/WePark/WeParkTests/TF220DiagnosticTests.swift`: loads these 8 tile JSONs via
`Bundle.main.url(forResource:withExtension:)` (confirmed this is the correct lookup — see
"Bundle mechanics" note below), decodes with the app's real `Segment`/`ParkingRule` Codable
models, and runs the real `ParkingRulesEngine.currentState(for:at:)` / `.safetyLabel(for:at:)`
over all 103 segments. Ran on a scratch simulator (`eng-tf220`, deleted after use) via
`xcodebuild ... -only-testing:WeParkTests/TF220DiagnosticTests test`.

**First run, date constructed as `DateComponents(year:2026, month:7, day:12, hour:17,
minute:0, timeZone: .easternTime)`:** a sanity assertion (`now.dayOfWeekET == 6` — the
diagnostic plan's assumption that 2026-07-12 is Saturday) **failed**:

```
TF220DiagnosticTests.swift:71: XCTAssertEqual failed: ("0") is not equal to ("6")
  — Expected Saturday (6) — day-of-week math is wrong if this fails.
```

`Calendar.easternTime` computed day-of-week `0` (Sunday) for 2026-07-12, not `6`
(Saturday). Independently verified this is correct, not a Swift `Calendar` bug, via three
unrelated methods:

```
$ cal 7 2026
     July 2026
Su Mo Tu We Th Fr Sa
          1  2  3  4
 5  6  7  8  9 10 11
12 13 14 15 16 17 18   <- 12 is under "Su"
...

$ python3 -c "import datetime; print(datetime.date(2026,7,12).strftime('%A'))"
Sunday
```

and Zeller's congruence by hand (h = 1 → Sunday in the 0=Saturday convention), all agreeing:
**2026-07-12 is a Sunday.** 2026-07-11 is the real Saturday.

With the assertion corrected to expect Sunday (`0`), and the harness run for real on the
actual bundled tile data:

```
=== TF2-20 diagnostic tally (real decoder + real engine + real tile data, 2026-07-12 17:00 ET [actually a Sunday]) ===
RED (restrictedNow): 18
AMBER (meteredActive + freeButRestrictionSoon): 0
GREEN (freeComfortably): 85
UNKNOWN: 0
TOTAL: 103
```

18/103 ≈ 17% red, 85/103 ≈ 83% green — "almost all of Bowery renders green," exactly as
Kevin described.

**Corroboration test** (`testBoweryStateTallyAtRealSat0711_5pmET_corroboration`): same 8
tiles, same engine, same harness, only the date changed to the *real* Saturday
(2026-07-11 17:00 ET, `dayOfWeekET == 6` confirmed):

```
=== TF2-20 corroboration tally: REAL Saturday 2026-07-11 17:00 ET ===
RED: 67  AMBER: 22  GREEN: 14  UNKNOWN: 0  TOTAL: 103
```

**Exact match** to the field-testing-log's hand-simulated 67/22/14 baseline. This proves the
baseline's *rule logic* was correct — it was simply computed for the wrong calendar date
(Saturday) and then compared against the app's real output for a different date (Sunday)
under a mistaken "these are the same day" assumption.

**Per-rule trace** (`testSingleNoStanding4to7SegmentTrace`), on a NO_STANDING rule with
`days=[1,2,3,4,5,6]` (Mon–Sat, i.e. "except Sunday") and no time ranges (all-day on matching
days), evaluated at 2026-07-12 17:00 ET:

```
category=noStanding desc=NO STANDING HOTEL LOADING ZONE --> (SUPERSEDES SP-1045BA)
  days=[1, 2, 3, 4, 5, 6] timeRanges=[] anytime=false
  -> isScheduleActive(Sat 17:00 ET)=false
nextRestriction: hours=168.0 label=No restrictions category=nil isActiveNow=false
currentState=freeComfortably
safetyLabel=Free severity=free
```

`isScheduleActive` correctly returns `false` because day-of-week `0` (Sunday, the real day)
is not in `[1,2,3,4,5,6]`. This is `isScheduleActive`/`ParkingRulesEngine` behaving exactly
as designed — an "except Sunday" rule is inactive on Sunday.

Directly relevant Bowery corridor rules cited in the field-testing-log as "ACTIVE at Sat
5pm" — `NO STANDING 4PM-7PM EXCEPT SUNDAY` and `2 HMP 10AM-7PM ... EXCEPT SUNDAY` meters —
are both explicitly Sunday-exempt by their own sign text. On the real Sunday they are
legitimately inactive, which is the dominant driver of the 85-green result.

### Step 2 — Bundle audit

- `diff -rq tiles ios/WePark/WePark/Resources/tiles` (repo source tree): **0 differences**,
  1033/1033 files identical (1032 `tile_*.json` + `index.json`).
- `project.pbxproj` uses `PBXFileSystemSynchronizedRootGroup` for the entire `WePark` folder
  root (both the `WePark` app target and `WeParkTests` target) — confirmed by direct read of
  the pbxproj. This means every file under `WePark/Resources/tiles/` is automatically
  included in both build products; there is no manually-curated file-reference list that
  could be stale after regen 6 added 8 new tile files.
- Built the app for the Debug/iphonesimulator configuration and inspected the actual
  produced `.app` bundle:
  - `1032` `tile_*.json` files present at bundle root (matches repo count exactly).
  - All 8 Bowery-covering tiles (`tile_10_12`, `tile_11_12`, `tile_6_10`, `tile_6_9`,
    `tile_7_10`, `tile_7_11`, `tile_8_11`, `tile_9_11`) present and **byte-identical**
    (`cmp -s`) to the repo copies.
  - All 8 regen-6-*new* tile files (`tile_1_13`, `tile_1_14`, `tile_2_13`, `tile_2_14`,
    `tile_20_22`, `tile_25_27`, `tile_26_7`, `tile_40_25`) also present and byte-identical.
  - The app's own `[TileLoader] index loaded: 1032 tiles, 39289 segments` log line at
    runtime (captured in the diagnostic test's console output) matches the repo's regen-6
    tile count exactly, corroborating the bundle audit from inside the running process.
- **Conclusion: bundle audit is clean.** Hypothesis (a) from the dispatch ("bundled
  Resources tiles ≠ repo tiles") is ruled out.

### Bundle mechanics note (test-harness correctness)

The `WeParkTests` target is a **host-application-hosted** unit test bundle
(`TEST_HOST`/`BUNDLE_LOADER = WePark.app`, confirmed in `project.pbxproj` build settings).
That means inside the test process, `Bundle.main` resolves to `WePark.app`'s bundle — the
same bundle `TileLoader.decodeTile(key:)` resolves against in production via
`Bundle.main.url(forResource:withExtension:)`. My first attempt used `Bundle(for:
TF220DiagnosticTests.self)` (the separate `WeParkTests.xctest` plugin bundle, which carries
no tile resources of its own) and every tile lookup failed with "not found in test bundle" —
this was a test-harness bug on my part, not evidence of anything; fixed by switching to
`Bundle.main`, after which all tile lookups succeeded and the harness became a faithful
reproduction of TileLoader's real runtime path.

### Step 3 — Runtime tile-load + recolor path (read-only review, no bug found)

Read `Services/TileLoader.swift` and the overlay rebuild path in `ContentView.swift`:

- `TileLoader.loadTiles(forRegion:)` decodes uncached tiles concurrently and merges into
  `segments` via `rebuildSegments(forKeys:)`. LRU cache (200-tile cap) does not affect
  correctness, only memory — evicted tiles are re-decoded from the bundle on next access
  (`TileLoader.swift:22-35, 248-254`).
- `ContentView.rebuildOverlays(at:)` (`ContentView.swift:954-1060`) computes
  `engine.currentState(for: segment, at: now)` **fresh, every call**, for every loaded
  segment — there is no cached/stale per-segment color that could survive past a rule
  boundary.
- Recolor triggers: 60-second `Timer.publish` (`ContentView.swift:1105`,
  `handleTimerTick()` at `ContentView.swift:2271-2274`, which sets `lastEvaluatedAt = .now`
  and immediately calls `rebuildOverlays(at: lastEvaluatedAt)`), plus segment-array-change
  and selection-change triggers (`handleSegmentsChanged`, `handleSelectionChanged`,
  `ContentView.swift:2276-2282`). All three call `rebuildOverlays` with a **live** `Date`,
  not a captured/stale one.
- `MapViewRepresentable.updateUIView` (`MapViewRepresentable.swift:712-718`) applies the
  `OverlayPayload` when `overlayPayload.generation` differs from
  `context.coordinator.lastAppliedGeneration` — a monotonically incrementing generation
  counter bumped on every `rebuildOverlays` call (`ContentView.swift:1049`,
  `1002`, `957`), so no overlay-application path can be silently skipped.
- **Conclusion:** no staleness bug in the runtime recolor path. This is consistent with
  the magnitude of the observed discrepancy (33 green → 14 green expected is not a
  "60-seconds-late" symptom; it's a full day-of-week's worth of rule state).

### Step 4 — Live repro

**Not performed as a live screenshot.** Two reasons, both examined and accepted:

1. **It would add no diagnostic value beyond step 1.** A screenshot cannot show *which
   calendar date/day-of-week* the render was computed against — the entire root cause is a
   date-label mismatch, which only a controlled, date-injectable test (step 1) can isolate.
   Step 1 already used the real decoder, real engine, and real bundled tile data — strictly
   more rigorous than an uncontrolled screenshot at "now" would be, since "now" during this
   diagnostic session is *also* Sunday and would just visually reproduce the same
   green-heavy map without proving *why*.
2. **The default map viewport doesn't render polylines without a zoom gesture.**
   `ContentView.polylineHideSpanThreshold = 0.04` (`ContentView.swift:530`) and the launch
   region span is `0.07`/`0.05` (`ContentView.swift:239`) — overlays are hidden until the
   user pinch-zooms in, which requires gesture injection unavailable in this sandbox (the
   same limitation `docs/qa/tf2-19-regen6-qa.md` and `docs/qa/tf2-17-18-chips-design-qa.md`
   both flag explicitly rather than skip silently).

Also checked: `parkUntilMode` defaults to `false` (`ContentView.swift:319`,
`@State private var parkUntilMode: Bool = false`) and is only set `true` from the
`ParkUntilSheet` confirm callback — ruled out "Park Until filter accidentally active" as a
contributing factor without needing a live screenshot.

---

## Root cause (single, high-confidence)

**Not a code defect.** The field-testing-log entry's premise — "Sat 2026-07-12 ~5pm ET" —
mislabels the day of week. 2026-07-12 is a **Sunday**. Bowery's two dominant corridor
restrictions cited in the log (`NO STANDING 4PM-7PM EXCEPT SUNDAY`, `2 HMP 10AM-7PM ...
EXCEPT SUNDAY`) are both explicitly inactive on Sundays by the sign text itself — so a
green-dominant map at that moment is the objectively correct rendering. The "67 RED / 22
AMBER / 14 GREEN" figure the log treats as ground truth is real and correctly computed, but
for the wrong day (the *real* Saturday, 2026-07-11) — this diagnostic's harness reproduces
that exact figure when pointed at the correct Saturday, and reproduces the observed
green-heavy result when pointed at the actual date in question.

No component in the pipeline needed to change: tile data (verified in TF2-19/regen-6 QA and
re-confirmed here), `Segment`/`ParkingRule` decode, `ParkingRulesEngine.currentState`/
`isScheduleActive`, bundle packaging, `TileLoader`, or the `ContentView`/
`MapViewRepresentable` overlay pipeline are all correct and consistent with each other.

## Recommended action

- **Close TF2-20 as "working as intended / not a bug."** No PR needed.
- **Process nit, not a code fix:** the field-testing-log's day-of-week labeling was
  the actual source of the confusion. Suggest future field-testing-log entries double-check
  day-of-week against the calendar (or state it as computed from the date, e.g. "2026-07-12
  (Sun)") rather than asserting it from memory, to prevent a repeat of this exact
  mislabel-driven false alarm.
- No spec change, no engineering follow-up, no blast radius — this is a diagnosis-closes-
  clean outcome.

## What was NOT changed

No production code was modified in this diagnosis. The only artifact is the scratch test
`ios/WePark/WeParkTests/TF220DiagnosticTests.swift`, committed to the isolated worktree
branch (`worktree-agent-af41044cdfdb7c154`, commit `999aaef`) but **not merged to `main`**
and **not part of a PR** — it exists solely to produce the evidence in this report and should
be deleted once TF2-20 is closed (or, at the orchestrator's discretion, could be trimmed and
kept as a permanent regression guard against a future real day-of-week bug, since it now
pins the correct 18/0/85 tally for 2026-07-12 and the correct 67/22/14 tally for
2026-07-11 — that's a product decision, not made here).
