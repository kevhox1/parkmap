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
| 14 | **FT-14 follow-up** — SAINT↔ST has no uniqueness gate; the doc claims 3 Saint-prefixed streets, there are 37. Zero collisions today; a future OSM refresh could silently attach signs to the wrong street. | VPS | Approved, queued |
| 15 | **FT-14 deferred** — 1,528-row zone-construction loss | VPS | Approved, queued |
| 16 | **Mapbox token restriction** — bundle-ID / URL scoping | VPS | Approved, queued |
| 17 | **FT-16a** — alerting for the staleness guard (nothing polls `ingest_runs.probe_status`) | VPS | Deferred by Kevin, named so it isn't lost |

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
