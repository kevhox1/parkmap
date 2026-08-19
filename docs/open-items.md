# WePark — Open Items Board (burn-down)

**Snapshot: 2026-08-19.** Every item that is genuinely open, and where it has to be done.
Kevin's directive: **clear all of these before taking on any new proposed changes.**

Source of truth remains `docs/field-testing-log.md` (per-item detail) and `HANDOFF.md` (state).
This file is the checklist view. **Update it as items close.**

Legend — **VPS** = runnable on the Linux box (specs, data pipeline, Supabase files, docs, git/PR).
**MAC** = requires Kevin's MacBook (Xcode, simulator, archive) or his hands (Supabase SQL Editor,
App Store Connect, real-device drive test).

---

## 🟡 IN FLIGHT — right now

| # | Item | Where | State |
|---|---|---|---|
| 1 | **Realtime Stream B** — WebSocket replaces the 8s poll + the Drive-Mode polling suspension | VPS (impl) → **MAC** (compile) | `@ios-engineer` **running**, ~11h in and actively writing. Worktree `agent-afee88c5a2f073a68`, branch `ios/supabase-realtime-stream-b`. **Uncommitted, unpushed.** New: `RealtimePinChannel.swift`, `RealtimeMergeGate.swift`; +724/−93 across 7 tracked files; currently in the test-writing phase |
| 2 | **FT-20 bottom sheet** — the build-17 payload after realtime | VPS → **MAC** | **Specced and cleared, NOT started.** Serialized behind #1 — both touch `ContentView.swift` |

---

## 🖥 PENDING KEVIN'S MAC — surface the moment he says he's back on a Mac

| # | Item | Notes |
|---|---|---|
| 3 | **Realtime Stream B compile + test** | Not yet available — branch isn't pushed. The moment #1 lands, hand Kevin the fetch + `xcodebuild test` block **unprompted** |
| 4 | **Build 17 archive → TestFlight** | `CURRENT_PROJECT_VERSION` is still **16**. Bump to 17 only after realtime **and** the FT-20 sheet are both merged |

Kevin (2026-08-19): *"I will commit later. Not on Mac. When I mention I am back on Mac next please
remind me and send me the code."* **Honor that — don't wait to be asked.**

*(Closed: PR #83 dark mode — merged `8b2840aa`, Kevin smoked it on-device, "Everything looks good.")*

---

## ⏳ OPEN — needs Kevin on the road or on his phone

| # | Item | Where | Notes |
|---|---|---|---|
| 5 | **TF2-16** — heading at intersection approaches | **phone** | **Still unverified after the build-16 drive** — Kevin: *"Unsure,"* he didn't watch for it. Carry into the build-17 drive as a named thing to look for |
| 6 | **FT-15 end-to-end submit** | **phone** | The one FT-15 path never exercised live. **Writes to production** — do it somewhere verifiable |
| 7 | **FT-21** — wide-street curb offset, lines mid-road on Houston/Bowery-class streets | VPS (decision) → **phone** | ⚪️ **Backburnered by Kevin.** **Re-confirmed still broken on the build-16 drive:** *"lines are misaligned/placed. They appear in the middle of the road."* Kevin wants an **architectural decision about how offsets are derived — not a fifth incremental tweak** |

---

## ✅ CLOSED ON THE BUILD 16 DRIVE — 2026-08-19

Four long-standing items died on real hardware. Recorded here so nobody re-opens them from a stale table.

| Item | Kevin | Note |
|---|---|---|
| **FT-19** | *"Lines look good"* | Lines stop short of intersections |
| **TF2-4** | *"Yes it's good now"* | **Open since 2026-06-08.** Cause was the setback coordinate mismatch (~32.8ft), not side-assignment or NYC data |
| **TF2-19** | *"Metered"* | **Open since 2026-07-09** — the finding that scrapped build 13 and forced the fail-closed completeness gate |
| **TF2-18 sunlight** | *"Yes you can read it in the sun/daytime"* | ⚠️ Resolved **on the light scheme** — dark mode is for *cleanliness*, **not** a legibility fix, and must not regress this |
| **FT-12 Parking 101** | *"it's there and it's good"* | |

---

## 🟡 OPEN — backend / data (VPS-only, no Mac needed)

| # | Item | Where | Notes |
|---|---|---|---|
| 8 | **FT-16a** — alerting for the staleness guard (nothing polls `ingest_runs.probe_status`) | VPS | ⚪️ Deferred by Kevin, named so it isn't lost |
| 9 | **Duplicate-adjacent-vertex tech debt** — see below | VPS | Fold into the next regen, don't spend a cycle on it alone |
| 10 | **359 still-lost zone rows** — the residue after the FT-14/FT-19 fix took 1,624 → 359 (−77.9%) | VPS | Not scheduled. The natural pairing for #9 |

**Duplicate-adjacent-vertex points in tile polylines: 12.4% → 22.7%** — a real, previously-undisclosed
side effect of the FT-14/FT-19 geometry fix (#80, merged). Found by QA re-running
`scripts/coverage-report.js` and noticing SoHo "regress" 73%→72%: the extra duplicate points shift
that tool's `line[Math.floor(length/2)]` neighborhood-attribution point across the SoHo/West Village
boundary for straddling streets. **Rule composition verified unchanged — this is a reporting artifact,
not rule loss.** But it roughly doubles the pre-existing "~6.8% degenerate segments" tech-debt note.
**Cheap fix:** skip pushing coordinate-identical points in `extractSubSegment()`'s result loop.
**Not cheap to validate:** it changes tile output, so it needs a regen + re-verify.

---

## 🗺 BUILD PLAN — decided 2026-08-19

**Build 17 = dark mode (✅ merged) + realtime WebSocket (🟡 in flight) + FT-20 bottom sheet (⬜ next).**
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
- **Verify `git branch --show-current` before every commit.** An agent dispatched *with* worktree
  isolation still left its branch checked out in the main checkout and an orchestrator commit landed
  on it silently.
- **Update the source-of-truth docs BEFORE dispatching when a standing instruction changes.** An
  agent correctly *refused* to start dark mode, citing three files that still said "do not start"
  after Kevin had lifted the backburner in conversation. Right behavior by the agent; the fault was
  dispatching against stale docs.

---

## Board hygiene

**This file went six days stale (2026-08-13 → 2026-08-19) while its lower half was kept current** —
the top tables still listed FT-17a, the build-16 archive, FT-18, PR #69 QA, FT-15 B2/B3/B4 and
realtime Phase 0/Stream A as open, all long since merged, and had two items numbered `18`. A fresh
session reading top-down would have been misled about the entire state of the project.
**Re-stamp the snapshot date and prune closed rows in the same commit that closes them.**
