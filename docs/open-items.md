# WePark — Open Items Board (burn-down)

**Snapshot: 2026-08-13.** Every item that is genuinely open, and where it has to be done.
Kevin's directive: **clear all of these before taking on any new proposed changes.**

Source of truth remains `docs/field-testing-log.md` (per-item detail) and `HANDOFF.md` (state).
This file is the checklist view. **Update it as items close.**

Legend — **VPS** = runnable on the Linux box (specs, data pipeline, Supabase files, docs, git/PR).
**MAC** = requires Kevin's MacBook (Xcode, simulator, archive) or his hands (Supabase SQL Editor,
App Store Connect, real-device drive test).

---

## 🔴 BLOCKING — build 16 can't ship until these clear

| # | Item | Where | State |
|---|---|---|---|
| 1 | **FT-17a** — Recenter pill only appears sporadically. Gesture detection scans `mapView.gestureRecognizers`, which never contains MKMapView's pan/pinch. | VPS (fix) → **MAC** (compile + smoke) | Fix agent running |
| 2 | **Build 16 archive** — version already bumped to 16 (`6bbb8514`); payload is FT-17 + FT-17a | **MAC** | Held on #1 |

---

## 🟡 IN FLIGHT — agents working now

| # | Item | Where | State |
|---|---|---|---|
| 3 | **FT-18** — Drive Mode button layout redesign toward Apple Maps | VPS (design doc) → VPS (impl) → **MAC** (smoke) | Designer running |
| 4 | **PR #69 QA pass 4** — verifies the column-GRANT narrowing + append-only ledger; must confirm it doesn't break the shipped write path | VPS | QA running |

---

## 🔴 OPEN — FT-15 (film-shoot sign feature), in dependency order

| # | Item | Where | Blocked on |
|---|---|---|---|
| ~~5~~ | ~~**PR #69** Stream A schema~~ — ✅ **DONE.** Pass 4 APPLY (live-executed against real Postgres). Merged `a646cf62`. | — | — |
| ~~6~~ | ~~**Apply `02f`**~~ — ✅ **DONE 2026-08-13.** Verified live: 2 new cols, 3 new tables, 2 storage policies, `created_at` non-insertable, locked cols non-updatable, 3 new constraints. | — | — |
| 7 | **PR #73** — Stream B4 fetch channel + banner. Isolation fix landed. | **MAC** (compile) | #6 — hard ordering: merging before the schema is live blanks the *entire* community-pin layer app-wide |
| 8 | **Stream B2** — map tap-select (pick the 4 blockfaces) | VPS → **MAC** (live-UI smoke) | FT-17a (same files) |
| 9 | **Stream B3** — write path + photo upload | VPS | #7 merging (same file) |

---

## 🔴 OPEN — realtime track (Kevin: hard TF2 requirement)

| # | Item | Where | Blocked on |
|---|---|---|---|
| 10 | **Phase 0** — add `supabase-swift` SPM package (Auth + Realtime), Xcode GUI, isolated commit | **MAC / Kevin** | Nothing — **available now** |
| 11 | **Stream A** — Auth/Keychain migration off `UserDefaults` | VPS → **MAC** | #10 |
| 12 | **Stream B** — Realtime WebSocket, replaces the 8s poll and the Drive-Mode polling suspension | VPS → **MAC** | #10 + FT-15 B3/B4 settling (same file) |

---

## 🟡 OPEN — backend / data (VPS-only, no Mac needed)

| # | Item | Where | Notes |
|---|---|---|---|
| ~~13~~ | ~~**Apply `02g`** + redeploy Edge Function~~ — ✅ **DONE 2026-08-13.** Verified live: `probe_status='stale'`, `stale_days=91`. FT-16 closed end to end. | — | — |
| ~~14~~ | ~~**FT-14 follow-up** — SAINT↔ST uniqueness gate~~ | — | ✅ **DONE.** Gate added to `osmName()`, mirroring the compact-spacing fallback's uniqueness pattern; the doc's false "3 Saint-prefixed streets" claim corrected (real count: 37); proven **byte-identical tile output** on a live-pull before/after, so no regen needed. |
| ~~15~~ | ~~**FT-14 deferred** — 1,528-row zone-construction loss~~ | — | ✅ **FIXED 2026-08-18**, bundled with FT-19 (same root cause) — `docs/qa/ft14-ft19-zone-geometry-fix.md`. `extractSubSegment()` is now the single place that translates raw distances into a block's local coordinate axis; short-block setback tapers instead of skipping. Citywide before/after: rows lost 1,624→359 (−77.9%), coverage 47%→48%, zero regressions. Kevin approved the regen; shipped this PR. |
| ~~16~~ | ~~**Mapbox token restriction**~~ — ✅ **RESOLVED as a no-op 2026-08-13** (`docs/mapbox-token-security.md`, merged #78). "Bundle-ID restriction" is not a real Mapbox feature; PWA token already URL-restricted, iOS token already separate + gitignored. Optional ~5-min dashboard labeling checklist remains for Kevin. | — | — |
| 17 | **FT-16a** — alerting for the staleness guard (nothing polls `ingest_runs.probe_status`) | VPS | Deferred by Kevin, named so it isn't lost |
| ~~18~~ | ~~**FT-19** — lines overshoot into intersections at road ends~~ | — | ✅ **FIXED 2026-08-18**, same PR/root-cause as item #15 above — `docs/qa/ft14-ft19-zone-geometry-fix.md`. Short-block setback skip replaced with a continuous taper; 81 blocks previously fully untrimmed now get a real, bounded setback. ⏳ Kevin on-device confirm (build 16+) still needed — the code fix and regen are done, but the visual "lines don't overshoot" claim is unverified off-VPS. |

---

## ⏳ OPEN — needs Kevin on the road or on his phone

| # | Item | Where | Notes |
|---|---|---|---|
| 18 | **Build 15 drive test** — FT-13 "?" button, Bleecker @ LaGuardia colored, Harlem coverage jump | **MAC / phone** | Build 15 is installed, unverified |
| 19 | **TF2-16** — heading locks at intersection approaches | **phone** | Carried over |
| 20 | **TF2-17/18** — "Free until X" chips + sunlight legibility | **phone** | Carried over |
| 21 | **TF2-19** — Bowery/Houston must read metered/no-standing **in-window** (weekday or Saturday; Sunday green is correct per TF2-20) | **phone** | Carried over |
| 22 | **Parking 101** — Settings row, large text sizes, fresh-install banner | **phone** | Carried over |
| 23 | **TF2-4** — school-zone wrong side on E 2nd St. **Blocked on Kevin: which two avenues?** | **phone** → VPS | Open since June |

---

## ⏳ BUILD 16 — SHIPPED, INSTALLED, **DRIVE TEST NOT YET DONE**

Build 1.0 (16) is on Kevin's phone and **statically verified** (FT-15 tap-select, FT-18 layout, FT-17a
Recenter, dark rendering, geometry inspected from a device screenshot). **He has NOT driven it yet
(as of 2026-08-19).** Everything below still needs a real drive:

| | |
|---|---|
| **FT-21** | Wide-street curb offset — lines mid-road on Houston/Bowery-class streets |
| **FT-19** | Do lines now stop short of intersections on short EV/LES cross-streets? (37 newly-trimmed blocks) |
| **TF2-4** | E 2nd @ 2nd–1st school zone — should sit ~33ft closer to the intersection |
| **TF2-16** | Heading locks at intersection approaches |
| **TF2-17/18** | "Free until X" chips + **sunlight legibility** (also the real gate for dark mode) |
| **TF2-19** | Bowery/Houston reading metered/no-standing **in-window** — weekday or Saturday; Sunday green is correct per TF2-20 |
| **Parking 101** | Settings row, large text sizes, fresh-install banner |
| **FT-15** | An end-to-end report submit — writes to production, do it somewhere verifiable |

---

## 🟢 NEW — tech debt discovered by QA, tracked not silently dropped

**Duplicate-adjacent-vertex points in tile polylines: 12.4% → 22.7%** — a real, previously-undisclosed
side effect of the FT-14/FT-19 geometry fix (#80, merged). Found by QA re-running
`scripts/coverage-report.js` and noticing SoHo "regress" 73%→72%: the extra duplicate points shift
that tool's `line[Math.floor(length/2)]` neighborhood-attribution point across the SoHo/West Village
boundary for straddling streets. **Rule composition verified unchanged — this is a reporting artifact,
not rule loss.** But it roughly doubles the pre-existing "~6.8% degenerate segments" tech-debt note.

**Cheap fix:** skip pushing coordinate-identical points in `extractSubSegment()`'s result loop.
**Not cheap to validate:** it changes tile output, so it needs a regen + re-verify. **Recommendation:
fold it into the next regen rather than spending a regen cycle on vertex hygiene alone** — e.g.
whenever the remaining **359 still-lost rows** get addressed. Kevin's call if he'd rather have it
before the next build.

---

## 🗺 BUILD PLAN — decided 2026-08-19

**Build 17 = dark mode + realtime WebSocket + FT-20 bottom sheet.**
**Build 18 = patrol mode / smart parking route.**

Kevin initially wanted all three in build 17; agreed to the split. The reasoning that decided it:

1. **`docs/smart-parking-route-2.0-concept.md` says not to start patrol mode until the realtime
   foundation is *solid* — and merged is not solid.** Solid means Kevin has driven Manhattan with a
   live WebSocket and it held. Shipping realtime in 17 and drive-testing it answers that *before* the
   flagship feature is built on top of it.
2. **Patrol mode is a different product behaviour, not a better app.** It's judged by actually hunting
   for a spot, which is a different drive test from "do the lines look right." Bundling it with two
   large UI changes confounds everything.
3. A testable build lands weeks sooner. **Build 13 became unshippable partly because too much landed
   at once.**

**Sequencing inside build 17:** realtime Stream B first (running), then the FT-20 sheet. Both touch
`ContentView.swift` — Stream B only a single `scenePhase` branch, the sheet a large diff — so they are
**serialized, not parallel.** This VPS has 2 cores; concurrent agents contend rather than parallelize.

---

## 🖥 PENDING KEVIN'S MAC — surface this the moment he says he's back on a Mac

**PR #83 — dark mode default.** Compiles unverified; needs `xcodebuild test` + a simulator smoke.
The distinctive check: **set the simulator to Light appearance and confirm the app still renders
dark** — that's the actual behavior under test. Command is in the session; regenerate if needed.

```
git fetch origin && git checkout -B ios/ft20-dark-mode-default origin/ios/ft20-dark-mode-default
```

Kevin (2026-08-19): *"I will commit later. Not on Mac. When I mention I am back on Mac next please
remind me and send me the code."* **Honor that — don't wait to be asked.**

---

## 🟡 ACTIVE — FT-20, backburner LIFTED 2026-08-19

Kevin had the design discussion and approved. **All six design decisions are settled** — see
`docs/field-testing-log.md` FT-20. In flight now:
- **Dark mode default** (split out, goes first) — `@ios-engineer`, running
- **Bottom-sheet navigation spec** — `@tech-lead`, running
- Original items 2 (browse chrome) and 3 (long button text) are **absorbed** by the sheet.

**FT-21** (wide-street curb offset) remains ⚪️ backburnered — see the field-testing log.

---

## 🔵 BACKLOG — not started, explicitly after the above

External TestFlight group (privacy URL ready) · FT-2 delete-own-pin (spec'd) · TF2-15 construction
layer (folded into FT-15's primitive) · tech-debt batch · FT-14's remaining gaps (~800 dead-end/ramp
rows unfixable by renaming; the larger "NYC posts no signs on many blocks" gap) · PWA `APP_VERSION`
label drift (cosmetic).

---

## Notes that affect sequencing

- **Kevin is the ONLY TestFlight user** (confirmed 2026-08-13). No external testers yet — the
  external TestFlight group is still a backlog item. This makes breaking changes *cheap*: data
  migrations, session resets, and state-dropping schema changes cost nothing right now and get
  expensive the moment external testers exist. Don't build migration shims for hypothetical users
  (this already saved the realtime Stream A work a `UserDefaults`→Keychain session shim). Revisit
  this assumption the moment the external group is created.

- **File contention is the real bottleneck, not agent capacity.** `MapViewRepresentable.swift`,
  `ContentView.swift`, and `CommunityPinService.swift` are each wanted by 2-3 streams. They must be
  serialized.
- **This VPS has 2 CPU cores.** Concurrent agents contend rather than parallelize — running 4-5 at
  once made each one dramatically slower in wall-clock. Keep it to 1-2.
- **Nothing in FT-15 is exposed today.** The abuse bypasses only become reachable once the schema is
  applied AND B4 ships. Finding them now is cheap; finding them later is not.
