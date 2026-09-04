# WePark — Open Items Board (burn-down)

**Snapshot: 2026-08-19.** Every item that is genuinely open, and where it has to be done.
Kevin's directive: **clear all of these before taking on any new proposed changes.**

Source of truth remains `docs/field-testing-log.md` (per-item detail) and `HANDOFF.md` (state).
This file is the checklist view. **Update it as items close.**

Legend — **VPS** = runnable on the Linux box (specs, data pipeline, Supabase files, docs, git/PR).
**MAC** = requires Kevin's MacBook (Xcode, simulator, archive) or his hands (Supabase SQL Editor,
App Store Connect, real-device drive test).

---

## 🖥 BUILD 17 — READY TO ARCHIVE (2026-08-22)

**Payload complete.** Dark mode (#83) + realtime WebSocket (#84) + FT-20 bottom sheet (#85/#86/#87).
`CURRENT_PROJECT_VERSION` = **17**. 804 tests passing, full live smoke passed on iPhone 17 / iOS 26.5.

**⏳ THE BUILD 17 DRIVE-TEST LIST — carry this into the car:**

| Item | What to watch for |
|---|---|
| **Realtime** | The whole point of build 17. Pins should update live, no 8s lag. **A silently-dead socket is the risk** — Drive Mode suspends the 45s poll backstop, so if pins freeze mid-drive, that's the failure mode to report |
| **TF2-16** | Heading at intersection approaches. **Never actually watched for on any drive** — came back "Unsure" last time. Watch for it deliberately |
| **FT-15 end-to-end submit** | The one FT-15 path never exercised live. **Writes to production** — do it somewhere verifiable |
| **S6 — sunlight** | The sheet's peek/medium chrome and the top-right rail in **direct sun**, windshield-mounted. TF2-18 logged a sunlight failure before; always-dark shipped for cleanliness, NOT legibility. No simulator can test this |
| **The sheet, in motion** | Does peek-only-search feel right while driving? Does "Find a Spot" read as the obvious action? |
| **FT-21** | Known broken (wide-street curb offset). Already decided A→B→C, lands build 18+. **No need to re-report** |

---

## 🟡 FT-2 FOLLOW-UPS — merged with known findings (2026-08-24, from `docs/qa/pr90-ft2-delete-own-pin.md`)

FT-2 merged (`2a6084d9`) after device smoke + QA. Two 🟡 findings were accepted as non-blocking
because neither is reachable through the shipped UI. **They are still real — do not let them evaporate.**

| # | Finding | Why it was not a blocker |
|---|---|---|
| **F1** | **AC-FT2.11 assumes an RLS-rejected DELETE returns 403. PostgREST's actual behaviour for a bare `USING` policy with no raising trigger — which `pins_delete_own` is — is *success with zero rows affected*.** So the client's `403 → httpError` branch (`CommunityPinService.swift:1512-1516`) is probably unreachable, and if the UI ownership guard were ever broken, deleting someone else's pin would show a **false "Report deleted."** ⚠️ **Not a security hole** — RLS still blocks the delete. But the UX would lie. **Verify the real status code with curl against production before treating AC-FT2.11 as closed**, then either correct the spec or make the client treat a zero-row response as failure |
| **F2** | **`pendingOptimisticDeletes` interference on a concurrent same-id delete.** `CommunityPinService.swift:1476-1479` sets the entry *conditionally* (`if capturedPin != nil`) but the `defer` at `:1479` clears it *unconditionally*. A second call for the same id — whose own `capturedPin` is nil because the first already removed the pin — still registers that defer and clears the first call's in-flight entry. `rollbackOptimisticDelete` (`:1539-1545`) could then resurrect a pin the server genuinely deleted | Not reachable via the shipped UI: the delete button is *replaced by a spinner* (not merely disabled) before a second tap can land, and `.confirmationDialog` fires its destructive action once. **The fix is small — make the `defer` conditional, matching the set** |

Also logged 🟢: the test-file header says "13 tests" but contains 12 (`FT2DeleteOwnPinTests.swift:14`) — the 830+12=842 arithmetic is right, only the comment is off by one.

**Still with no device evidence:** AC-FT2.13(e), "no delete button on someone else's pin." Kevin had no other users' pins to test against. QA verified the predicate by trace — `isOwnPin` compares `author_id`, a **base-table** column that IS present in Realtime WAL payloads (only the view-joined `author_username` is absent), so it holds for Realtime-delivered pins too.

---

## 🟡 IN FLIGHT — right now

| # | Item | Where | State |
|---|---|---|---|
| 1 | **FT-20 bottom sheet** — the remaining build-17 payload | VPS → **MAC** | Design review ✅ · **Stream A ✅ MERGED `37aa8c01`** (748/748, live smoke passed) · **Stream B ✅ MERGED `c1d2f60d`** (776/776 after a Mac-caught 50/50 tie-break bug in the scorer) · **Stream C ⬜ NEXT** (~1.5–2, the big one) · QA ~1–1.5 over 2 passes |
| 1b | **Stream C's definition of done** — it has grown; all of it lands in ONE change | VPS → **MAC** | Mount the sheet at cold launch · delete `gearButtonOverlay`/`driveEntryButton`/`driveModeDestinationCover` · delete `DriveModeDestinationView.swift` · collapse the duplicated `onRouteReady` · relocate Park Until to the top-right rail · wire the Drive-Mode boundary (AC-28/29a) and the FT-15 block-select boundary (AC-23–27/S4) · fix spec §0d's **C1** (`searchArea` frame constraint — the `List`-greedy-sizing trap) and **C2** (error banner invisible below `.large`) · **flip `ft20BrowseSheetEnabled`**. ⚠️ **First stream whose result is visible — needs a real live smoke, not just a green build** |
| 1a | ⚠️ **`ft20BrowseSheetEnabled` is `false` on `main`** | VPS | Stream A is merged but **inert** — the sheet is invisible to users until Stream C flips the gate. This is deliberate: it kept `main` shippable while A landed. **Stream C must flip it and land the cold-launch mount + both boundaries in the same change.** Greppable: `ft20BrowseSheetEnabled` in `ContentView.swift` |

---

## 🖥 PENDING KEVIN'S MAC

| # | Item | Notes |
|---|---|---|
| 2 | **Build 17 archive → TestFlight** | `CURRENT_PROJECT_VERSION` is still **16**. Bump to 17 only after the FT-20 sheet merges — dark mode and realtime are already in |

Kevin (2026-08-19): *"I will commit later. Not on Mac. When I mention I am back on Mac next please
remind me and send me the code."* **Honor that — don't wait to be asked.**

*(Closed: PR #83 dark mode — merged `8b2840aa`, Kevin smoked it on-device, "Everything looks good.")*
*(Closed: PR #84 realtime Stream B — merged `5d4604a6`. Kevin compiled on his Mac: **730/730 passed,
0 failed, 0 skipped**, iPhone 17 / iOS 26.5. Two QA passes; pass 1 found a lifecycle race, pass 2
verified the fix and returned MERGE.)*

---

## ⏳ OPEN — needs Kevin on the road or on his phone

| # | Item | Where | Notes |
|---|---|---|---|
| 5 | **TF2-16** — heading at intersection approaches | **phone** | **Still unverified after the build-16 drive** — Kevin: *"Unsure,"* he didn't watch for it. Carry into the build-17 drive as a named thing to look for |
| 6 | **FT-15 end-to-end submit** | **phone** | The one FT-15 path never exercised live. **Writes to production** — do it somewhere verifiable |
| 7 | **FT-21** — wide-street curb offset, lines mid-road on Houston/Bowery-class streets | VPS (spec) → VPS (impl + regen) → **phone** | ⚪️ Backburnered but **NO LONGER UNDECIDED.** Kevin ruled 2026-08-19: **(A) per-carriageway offset from CSCL's own divided-street modeling first → (B) real curb geometry from NYC planimetric sidewalk polygons if A fails → (C) declare cosmetic.** Start with one tech-lead session to confirm CSCL supports (A). **Must NOT ship in build 17** — a regen would confound the realtime drive test. Build 18 at the earliest. See `field-testing-log.md` FT-21 |

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
| 9 | **Duplicate-adjacent-vertex tech debt** — see below | VPS | Fold into the next regen, don't spend a cycle on it alone. **That regen is now most likely FT-21's** (#7) — bundle them |
| 10 | **359 still-lost zone rows** — the residue after the FT-14/FT-19 fix took 1,624 → 359 (−77.9%) | VPS | Not scheduled. The natural pairing for #9 — **same FT-21 regen, three items one validation pass** |

| 12 | **PR #95 gate findings — four UX items, all deferred to build-20 hero sessions (Kevin + QA, 2026-08-28)** | VPS (S13 scope) | ① Long-press report entry takes two attempts to stay up (leave alone — S13a's Report pill replaces the entry) · ② sweeper passed/approaching chips toggle correctly but selected-state affordance is too weak to notice · ③ taxonomy copy overlap: "Cleaning truck" sub-tag under Enforcement vs the separate "Street sweeper" type (pre-existing FT-11 copy; prototype's 🎫/🧹 split resolves it — S13c verbatim pass) · ④ confirm-the-street section can mount below the sheet's visible fold — logic fine, discoverability flaw (S13 layout parity) · ⑤ (added 2026-09-01, #97 gate) "0% accurate" shows for a new user whose only reports are merely unconfirmed — arithmetically honest, reads punitive; widen the em-dash guard to unconfirmed-only profiles in S13. None block #95/#97 |
| 13 | **Foreground double-POST of device_push_tokens** (PR #101 QA pass 2, finding #6) | VPS | 🟢 Non-blocking fast-follow: `.active` fires `updatePushZoneFromParkedCarOrLocation()` + `handleAppForeground()` back-to-back, both POSTing before `lastUploaded` updates. Idempotent since the on_conflict fix — pure waste, no harm. Fix: drop the redundant second call or add an in-flight guard. Fold into S13a's ContentView touch |
| 11 | **Diagonal/off-street curb lines in Chinatown–Civic Center** — green segments cutting across block interiors near White St / Benson Pl / NYU Lafayette Hall and Columbus Park; several other lines not hugging their streets | VPS (investigate) | ⚪️ **BACKBURNERED by Kevin 2026-08-28: "look at after all the hero builds are finished."** Observed in the iOS sim during the Phase-1 smoke (build-20 branch, but almost certainly pre-existing tile data, not Phase-1 code — Phase 1 touches no geometry). Probable kin of #9/#10 (same regen would validate all three) and of FT-21's geometry family. Do NOT start before build 20 wraps |

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

**Build 17 = dark mode ✅ + realtime WebSocket ✅ + FT-20 bottom sheet (🟡 Stream A ✅ / B in flight / C next).**
**Build 18 = patrol mode / smart parking route + iCloud parked-car sync + FT-2 delete-own-pin.**

**🆕 BUILD 18 SCOPE ADDED 2026-08-20 — both driven by WePark now having external users:**
- **iCloud key-value sync for the parked car** (`NSUbiquitousKeyValueStore`). Today the parked car is
  a JSON blob in `UserDefaults.standard` (`ParkPinService.swift:45`) — **device-local**, so a user
  cannot see their car on a second device and **loses it permanently on delete-and-reinstall.** Kevin
  chose this over an account system: no login, no UI, no sign-up friction, tied to the user's Apple
  ID rather than the app container, and close to a drop-in replacement for the existing read/write.
  **Explicitly NOT building accounts** — the zero-friction "open it and see the map" onboarding is
  worth protecting, and accounts are build-sized (sign-up, reset, Sign in with Apple, anon→account
  migration, RLS rework). The long-term shape if ever needed: anonymous by default, *optional* Sign
  in with Apple that **links** the existing anonymous identity rather than replacing it.
- **FT-2 — delete your own pin.** Spec exists: `docs/ft2-delete-own-pin-spec.md`. Now a real gap
  rather than a nicety: strangers are using the app and someone will misreport a block with no way to
  retract it. ⚠️ **Needs an RLS policy change (delete where `reporter_id = auth.uid()`) — Kevin
  applies all Supabase migrations to production by hand. Agents write the migration file and stop.**

**⚠️ BUILD 18 IS ACCUMULATING AND IS STILL UNSIZED.** It now holds patrol mode (5 sub-PRs, W8.5e–i,
never estimated) **plus** two new items. Build 13 became unshippable because too much landed at once —
the same risk applies here. **Size patrol mode before starting it**, and be willing to split 18 rather
than let it grow the way 13 did.

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

~~External TestFlight group~~ ✅ **DONE 2026-08-20 — build 16 passed Beta App Review, public link
live** · FT-2 delete-own-pin (spec'd) · TF2-15 construction
layer (folded into FT-15's primitive) · tech-debt batch · FT-14's remaining gaps (~800 dead-end/ramp
rows unfixable by renaming; the larger "NYC posts no signs on many blocks" gap) · PWA `APP_VERSION`
label drift (cosmetic).

---

## Notes that affect sequencing

- **🔴 SUPERSEDED 2026-08-20 — KEVIN IS NO LONGER THE ONLY TESTFLIGHT USER.** Build 16 passed Beta
  App Review and is **distributed externally with a public TestFlight link.** The assumption below
  held from 2026-08-13 to 2026-08-20 and is now **void**. What changes:
  - **Breaking changes are no longer free.** Data migrations, session resets, and state-dropping
    schema changes now cost real users their data. The old note said to revisit this "the moment the
    external group is created" — that moment has arrived.
  - **Anonymous identity is now load-bearing for people who aren't Kevin.** `SupabaseAuthService`'s
    reasoning that "the worst case on upgrade is a fresh anonymous identity" was costed against a
    single user who could shrug it off. An external tester losing their session loses their saved car
    and their report history with no way to recover it — there is no account to sign back into.
  - **Migration shims are no longer hypothetical.** The old advice not to build them was correct
    *then*; re-evaluate per change now rather than defaulting either way.
  - **FT-21 and the coverage gaps are now visible to strangers.** Both are named as known issues in
    the What-to-Test copy so they don't generate duplicate reports.
  - **TestFlight crash reports and feedback start arriving.** Nothing polls them today. Worth a
    habit, not a feature.
  - *(Historical, for context — the assumption this replaces: Kevin was the only TestFlight user,
    confirmed 2026-08-13, which made breaking changes cheap and saved the realtime Stream A work a
    `UserDefaults`→Keychain session shim. That saving was correctly banked at the time.)*
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
