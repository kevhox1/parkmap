# Patrol Mode / Smart Parking Route — Feasibility Spec

**Status:** Feasibility spec — answers "can this be built well, and what does it cost," not a build
order. This is the gate `docs/smart-parking-route-2.0-concept.md` §6 item 4 requires ("a proper
tech-lead feasibility spec... before any code"). No code should be dispatched against this doc until
Kevin has ruled on §0's naming question and §7's open decisions.
**Author:** @tech-lead
**Date:** 2026-08-24
**Supersedes:** nothing. Sits downstream of `docs/smart-parking-route-2.0-concept.md` (the vision),
`docs/build-18-sizing.md` (the sizing pass that found the ambiguity resolved below), and
`docs/drive-mode-scope-spec.md` §2/§7 (the other, now-stale "patrol mode" — see §0).
**Roadmap placement:** per `HANDOFF.md`'s 2026-08-24 changelog, "patrol mode (either reading) is
build 20+." This spec concerns the feature that will occupy that build number once it exists.

---

## Read this first — three-line summary for Kevin

1. **"Patrol mode" means the coverage-sweep smart parking route** (`smart-parking-route-2.0-concept.md`),
   not the Tier-3 crowd-reporting UI — see §0 for the evidence. **Recommend retiring the name
   "patrol mode" entirely** — it's collided with two unrelated features twice now.
2. **This should NOT start until you've confirmed the build-18 drive test held** — specifically that
   the realtime socket did not silently die mid-drive. That gate is unmet as of this writing (§4).
3. **Full sizing is 10–17 engineering+QA sessions, plus an iteration tail that is genuinely
   open-ended** because correctness here can only be judged by a real drive that finds a spot — no
   simulator, no unit test, no debug overlay can verify it (§6). **Recommend a much smaller v1** that
   proves the concept without the hardest pieces (§7).

---

## §0 — Resolving the naming ambiguity (must read before anything else in this doc)

**Verified directly against the running code, not against the planning docs' descriptions of it:**

| Claim | Verification | Result |
|---|---|---|
| `PinType` has no `.openSpot` case | `ios/WePark/WePark/Models/CommunityPin.swift:48-63` — full enum listing, no `open_spot` | ✅ confirmed absent |
| `DriveModeStyle.patrol` was deleted | `ContentView.swift:107` — *"DriveModeStyle.patrol case REMOVED (per OQ-NR3 decision)"*; current enum (`ContentView.swift:300-309`) has exactly `.inactive` / `.destination` / `.cruise` | ✅ confirmed absent |
| `PatrolModeService.swift` / `PatrolView.swift` have never existed | `git log --all --diff-filter=A -- '**/PatrolModeService.swift' '**/PatrolView.swift'` → empty | ✅ confirmed — zero commits, any branch, ever |

Both of `docs/build-18-sizing.md` §0's load-bearing claims hold. **This spec is about reading (b): the
coverage-sweep smart parking route** (`docs/smart-parking-route-2.0-concept.md`), not reading (a) (the
already-95%-shipped Tier-3 crowd-reporting UI, `docs/tier3-patrol-mode-buildplan.md`). Evidence for why
(b) is the intended referent going forward, beyond the elimination above:

- `docs/ft20-bottom-sheet-navigation-spec.md` OQ-4 (Kevin-approved, 2026-08 — the most recent
  product-direction statement touching this feature) says explicitly: *"the way it works in the future
  is to score parking nearby and direct the driver through the optimal path (to find parking) nearby
  the target destination... OQ-4's scoring should be factored as reusable logic, not a one-off
  chip — it is the same scoring the routing feature will need, applied to a point rather than a
  path."* That is a description of (b), not (a).
- `ParkingProximityScorer.swift` (`ios/WePark/WePark/Services/ParkingProximityScorer.swift:1-45`) was
  built during FT-20 with a doc comment that names this exact future feature as its reason for
  existing — again, describing (b)'s per-candidate-node scoring, not (a)'s claim mechanic.
- Reading (a)'s remaining work (`open_spot` pins + claim mechanic) is real but small (`build-18-sizing.md`
  §1a, ~2.5–4.5 sessions) and does not need a feasibility spec — it's UI-pattern-extension work on an
  already-proven pipeline. Reading (b) is the one `smart-parking-route-2.0-concept.md` §6 explicitly
  gates on a feasibility spec before any code. This document is that gate.

### Recommendation: retire "patrol mode" as a name, project-wide

The term has now collided with two unrelated features (Tier-3 reporting UI, then this) and been
formally un-collided once already (`HANDOFF.md` 2026-06-06: *"DROPPED the separate 'Patrol mode.'
Reporting is now UNIVERSAL"*). A third collision is a naming failure, not a coincidence. **Working
name for the rest of this document: "Smart Sweep."** Final user-facing copy is a `@designer` decision
layered onto whatever UI entry point ships — see §1's framing recommendation, which argues this should
not be a new top-level "mode" at all, but an upgrade to the existing "Find a Spot" entry
(`ContentView.swift:1841`, `docs/ft20-bottom-sheet-navigation-spec.md` line 230's "RULING 2 —
'Cruise' is renamed to 'Find a Spot'"). **Open decision — see §7.1.**

---

## §1 — Problem and user story

### Kevin's framing (verbatim, per the task)

> "score parking nearby and direct the driver through the optimal path (to find parking) nearby the
> target destination."

### What exists today that this framing already half-describes

This is the single most important finding in this spec, and it changes the sizing and the
recommended v1 substantially from what `docs/drive-mode-scope-spec.md` (2026-05-18, pre-dates all of
this) or `docs/build-18-sizing.md`'s placeholder number assumed.

**Cruise Mode ("Find a Spot") already ships** (`DriveModeStyle.cruise`, `ContentView.swift:300-309`,
`enterCruiseMode()` at `ContentView.swift:2159-2168`). A driver with no destination taps "Find a Spot"
in the browse sheet and gets: GPS follow, heading-up camera, `DrivingContextService` narrating
free/metered/restricted per side of every block they pass (`CruiseVoicePolicy.swift`), a bottom card
(`DriveModeBottomCard.swift`), a "Park here" button that runs a sign-check checklist then drops a pin
(`docs/tf2-7-cruise-guidance-spec.md`, shipped), and an unconditional one-tap "End" control
(`endDriveControl`, `ContentView.swift:1893-1920`). **What it does NOT do is direct anything** — it is
purely reactive commentary on whatever street the driver happens to already be driving down. There is
no suggestion of which way to turn, no notion of "you've already seen this block," no route.

**Smart Sweep's actual job, stated precisely: turn Cruise Mode from reactive to directive.** Not a
new mode from scratch — an enhancement of the one that exists. See §7.1 for why this reframing matters
for sizing and for the naming decision in §0.

### User story (with a real beginning and end — the part most likely to be underspecified)

> As a driver with no fixed destination, cruising for parking with "Find a Spot" active, I want the
> app to tell me not just "this block is free/metered/restricted" but "which way to go next for
> better odds" — so instead of driving in circles hoping to notice an opening, I'm being steered.

**Begins:** the driver is already in Cruise Mode (existing entry point, existing GPS/voice/camera
session). No new "start Smart Sweep" action for v1 — see §7.2's recommended slice.

**Ends — three ways, all of which should be the SAME three ways Cruise Mode already ends, not new
ones:**
1. **"Park here"** → existing sign-check → pin drop → `endDriveMode()`. Unchanged.
2. **"End"** → `endDriveMode()` immediately, no dialog. Unchanged.
3. **The sweep itself has nothing left to offer.** This is the one Cruise Mode doesn't currently need
   to answer, because it never runs out of things to narrate — it just keeps talking about whatever
   block you're on. A directive feature has to define what happens when there's no good "next
   direction" to give (see §5 "whole area scores badly"). **For the v1 slice in §7.2, this case does
   not need new UX at all** — v1 gives a "best next turn" cue rather than a persisted route, so it
   degrades to silence/no-suggestion exactly the way `CruiseVoicePolicy.shouldAnnounce` already
   degrades to silence on an all-restricted block (`CruiseVoicePolicy.swift:13-19`). **A full
   persisted loop-route (v2, §7.3) does need this answered** — an explicit "you've covered the area;
   nothing better than what you already passed" end-of-sweep state, new copy, new UX. Flagged as an
   open decision in §7.3, not resolved here.

---

## §2 — Algorithm feasibility: does the PWA's `generateParkingRoute` port cleanly?

**Reference implementation:** `index.html:7038-7157` (`generateParkingRoute`), backed by
`loadStreetGraph` (`index.html:1803-1850`), `attachBlockFacesToEdges` (`index.html:1923-1969`), and
`scoreEdgeCoverage` (`index.html:1976-2006`). It works today on the web — this is real, proven logic,
not a sketch.

### What it actually does (verified by reading it, not by the concept doc's description of it)

It is a **static, one-shot greedy graph walk**, computed once when the button is tapped:

1. Load a directed street graph from `osm_oneway.json` (nodes = intersections snapped to an ~11m
   grid, edges = one-way-aware directed street segments) — `index.html:1803-1850`.
2. Snap the start point (car pin or map center — **never a destination**; see the mismatch below) to
   the nearest graph node.
3. Attach the currently-loaded block-face segments to their nearest matching directed edge by street
   name + geometry proximity — a one-time spatial join, cached — `attachBlockFacesToEdges`.
4. Greedily walk the graph: at each intersection, score every outgoing edge (`scoreEdgeCoverage`) by
   its unscanned block faces' durability (ASP-done ≥48h scores 10, partial scores `hours/6`, metered
   scores 0.5), penalize revisits heavily (`-100 × visit count`), slightly penalize edge length, and
   after 60% of a fixed 2500m/120-step budget is spent, bias toward edges that close the distance back
   to the start. Stop on budget exhaustion or on closing a loop near the start.
5. Render the walked path as a polyline, highlight every scanned block face, and **hand off actual
   turn-by-turn navigation to Apple/Google Maps via a URL scheme** (`openSmartMoveRoute` pattern,
   `index.html:7271-7294`) — the PWA does not drive the user through its own route live. It computes
   the loop once, shows it, and lets an external app do the driving.

### Two things it assumes that don't hold in the current app, and one it doesn't do at all

1. **It has no destination anchor.** The concept doc (§2, §3) frames the reward as
   `... × g(proximity to anchor)`, anchored to "either the destination OR the current location." The
   reference implementation only ever anchors on the current location/car pin — there is no
   destination-anchored version of it anywhere, in the PWA or the iOS spec history. Kevin's verbatim
   framing in the task ("nearby the target destination") assumes the destination-anchored variant
   exists as prior art. **It doesn't. It would need to be designed, not ported** — likely by biasing
   the greedy walk's edge scoring toward edges that reduce distance-to-destination throughout, not
   just in the final 40% the way the current loop-closing bias works. This is new algorithm design,
   not translation.
2. **It has no live re-planning.** The route is computed once and handed to an external app. Nothing
   in the reference implementation re-scores as the driver actually moves. Kevin's own description
   ("as they're driving around... they would start being told") implies an in-app, live, continuously
   narrated experience — closer to Cruise Mode's existing live loop than to the PWA's
   compute-once-then-leave-the-app pattern. **Porting the algorithm cleanly does not give you the
   experience Kevin described** — the experience has to be built new on top of Cruise Mode's existing
   live GPS/voice/camera loop (§1), using the ported algorithm as one input, not as the whole feature.
3. **The graph itself does not exist on iOS at all.** No `osm_oneway.json` is bundled
   (`find ios/WePark -iname '*oneway*'` → nothing), no `StreetGraph` type, no A*/greedy-traversal
   code, no node/edge model. `RouteService.swift` only wraps Mapbox's HTTP Directions API between two
   coordinates (`RouteService.swift:127-165`) — a fundamentally different capability from a local,
   open-ended graph walk with no fixed destination. **This is the single largest net-new engineering
   primitive this feature requires**, and it's the one none of the existing prior art (`drive-mode-scope-spec.md`'s
   ~7.25-session patrol-mode estimate, `build-18-sizing.md`'s 10-20+ placeholder) priced with the
   benefit of knowing it doesn't exist at all today. Bundling a ~1.2MB JSON asset is not novel for this
   app (`Resources/asp-2026.json`, `Resources/tiles/*.json` — the exact same "parse a JSON blob into
   an in-memory Swift model at launch" pattern `TileLoader` already implements), so the *precedent* is
   good; the *graph model + traversal + edge-to-blockface join* is genuinely new code, not a config
   change.

### Verdict

**The core insight (greedy graph walk, coverage/durability scoring, revisit penalty, budget cap)
ports cleanly as an *algorithm*.** It's well-specified, already tuned against real Manhattan geometry,
and translates to Swift mechanically. **What does NOT port cleanly is the experience shell around it**
— the PWA's one-shot-then-hand-off-to-Apple-Maps pattern is the opposite of what this feature needs to
be on iOS, and the destination-anchored variant Kevin describes has no reference implementation at
all. Budget for algorithm *design*, not just algorithm *translation*, on both of these points.

---

## §3 — Does `ParkingProximityScorer` actually fit, as FT-20 intended?

**Partially — and the gap is worth naming precisely, because the FT-20 doc comment's framing oversold
the fit.**

`ParkingProximityScorer.swift`'s header (`:1-45`) states the greedy traversal "can call
`ParkingProximityScorer.score(near:)` once per candidate node instead of re-deriving classify-and-bucket
from scratch." Checking that against what `score(near:)` actually does (`ParkingProximityScorer.swift:185-262`)
versus what the traversal actually needs:

| `score(near:)` does | The greedy traversal needs |
|---|---|
| Scans ALL segments within a fixed radius (100m default) of a single point, deduped by `Segment.blockfaceKey` | Per-**directed-edge** ownership of block faces — an edge's score must reflect only the faces attached to *that* edge, not every face within 100m of its midpoint (at a 4-way intersection, a 100m radius covers faces belonging to 3+ different outgoing edges) |
| Buckets into free/mixed/restricted (3-way qualitative label) | A continuous score that bakes in **durability** (hours until next restriction) — `scoreEdgeCoverage`'s whole point is that "ASP done in 2 hours" outscores "ASP done in 20 minutes," a distinction the 3-bucket scorer collapses entirely |
| No concept of "already scanned" | Coverage dedup (has this block face already been counted on an earlier step of this walk) is core to why the traversal explores outward instead of camping on one good block |
| No concept of a directed edge at all | Everything — the traversal's fundamental unit of choice is "which outgoing edge do I take," not "how good is the area around this point" |

**What DOES transfer cleanly, and is worth keeping:** the skip-category set (`.noStanding, .noParking,
.special, .truckLoading, .unknown`) and the general "classify via the shared rules engine, don't
invent a second classifier" discipline (`ParkingProximityScorer.swift:26-40`) — both should be reused
verbatim by whatever edge-scoring function Smart Sweep needs, for the same consistency reason FT-20
argued for. **What does NOT transfer is the scorer itself as a drop-in per-node call** — the traversal
needs something closer to the PWA's `attachBlockFacesToEdges` + `scoreEdgeCoverage` pair (precise edge
ownership + durability-weighted score), which is a different, new function, not a reuse of
`score(near:)`. `ParkingProximityScorer` remains genuinely useful for Smart Sweep in a narrower role:
a cheap "how's the neighborhood generally" gut-check (e.g., a quick sanity readout, or scoring a
handful of candidate next-turns when the full edge-attachment machinery is overkill) — but it is not
the traversal's core scoring function, contrary to what its doc comment implies. **This should be
corrected in the FT-20 doc comment once Smart Sweep's actual scoring function exists**, so a future
reader doesn't repeat the assumption.

### Are `RouteService.pickBestParkingAwareRoute`'s +3/+1 weights the right ones at route/edge scale?

**No — they solve a different problem and shouldn't be reused as-is.** `pickBestParkingAwareRoute`
(`RouteService.swift:222-315`) compares 2-3 *whole, already-computed* Mapbox route alternatives by
summing +3 per free block face and +1 per metered block face along each route, minus a duration
penalty — a **route-selection** heuristic, evaluated once per candidate route. The greedy traversal
needs a **per-edge, per-step** heuristic evaluated dozens of times per drive, and the PWA's own
`scoreEdgeCoverage` (`index.html:1976-2006`) already uses a materially different weighting: durability
baked directly into the score (ASP-done ≥48h = 10, partial = `hours/6`, metered = 0.5 — not a flat
+3/+1), a `-100 × visit count` revisit penalty, a distance penalty, and a budget-phase steering bonus.
**These are not interchangeable weighting schemes for two different problems that happen to share a
skip-category set.** Smart Sweep's edge scoring should be a new function modeled on
`scoreEdgeCoverage`, not a reuse of `pickBestParkingAwareRoute`'s weights. Where the two SHOULD stay
consistent is the underlying classification (`ParkingRulesEngine.currentState`/`safetyLabel` — the one
canonical source of truth, per FT-20's own S2 finding) — just not the score constants layered on top
of it.

---

## §4 — The realtime dependency: what exactly does the drive need to prove?

`docs/smart-parking-route-2.0-concept.md` §6 item 1 gates this whole feature on "core app +
supabase-swift real-time (hard TF2 requirement)." **As of this writing that gate is unmet.**
`HANDOFF.md`'s most recent changelog entry (2026-08-24, "BUILD 18 SHIPPED TO EXTERNAL") states: *"THE
BUILD 18 DRIVE TEST IS NOW THE GATE ON EVERYTHING ELSE... Watch for a silently dead socket: Drive Mode
suspends the 45s poll backstop, so pins freezing mid-drive with no error is THE failure mode to
report."* No later entry records that drive having happened.

### A worth-naming tension: does Smart Sweep's own v1 algorithm actually consume realtime data?

Read literally, no. `smart-parking-route-2.0-concept.md` §5's v1 ("legality + durability + coverage
heuristic... no occupancy") scores purely off the static rules engine (ASP calendar, metered hours)
and the static street graph — neither of which is realtime data. The realtime channel exists to push
Tier-3 crowd pins (`enforcement_active`, `sweeper_passed`, etc.) between clients within ~5s. Smart
Sweep v1 as scoped doesn't read those pins at all. **So the strict technical dependency is weaker than
the concept doc's gate implies.** The more likely reason for the gate, reading the project's own
history: this mirrors exactly the rationale that gated the original Drive Mode v1 build on a PWA
drive-test (`docs/drive-mode-scope-spec.md` §8 — "building on top of design choices that have never
met real road conditions is a compounding risk") — it's a **prudential** gate about shipping a
flagship, hard-to-verify feature on an app whose live-data plumbing hasn't been proven in a moving car,
not a literal data-flow coupling. **This is worth a direct question to Kevin (§7.4)** rather than
silently either honoring or overriding the gate — but the working assumption in this spec is to honor
it, since second-guessing a standing instruction without asking is exactly the failure mode this
project's own process notes warn against.

### The checkable version of the gate

Per `HANDOFF.md`'s own framing, the drive test passes when, specifically:
1. **The realtime socket does not silently die mid-drive.** A dead socket produces no error — pins
   simply stop updating. This is the named failure mode to watch for.
2. Pins inserted by another client appear within ~5s on the driving client (the basic realtime
   contract, previously proven only outside a moving car / cell handoff conditions).
3. Reconnect behavior after a tunnel/dead-zone/backgrounding holds (implied by "solid," not
   separately named in HANDOFF, but the same failure class as #1).

**Smart Sweep should not start until `HANDOFF.md` records that this specific drive happened and these
held.** That's a checkable gate, not a vibe — grep the changelog for a post-2026-08-24 entry
confirming it before dispatching any Smart Sweep engineering.

---

## §5 — Hard problems, named

1. **The route-vs-reactive-cue framing decision (§1, §7.1) is the single highest-leverage design
   choice in this feature**, and it's currently unmade. Get it wrong and either (a) v1 ships a
   full persisted route with all of #2–#4's problems below on day one, or (b) v1 ships something too
   thin to be worth a real drive test.
2. **A persisted route changing under you as pins expire or as real driving deviates from the graph
   path.** The PWA sidesteps this entirely (static, one-shot, handed off to another app). An in-app
   live version has to decide: does the suggested path silently re-derive when the driver deviates
   (risk: constant re-suggestion, motion-sickness-adjacent map churn), or does it hold the original
   path and just go quiet/stale if ignored (risk: confidently wrong advice)? Destination-mode Drive
   Mode already punted on the analogous problem (`docs/drive-mode-scope-spec.md` §9: "re-routing on
   deviation... defer to v1.1") — Smart Sweep doesn't have the luxury of punting the way destination
   mode did, because there's no destination to fall back on showing; the suggested direction *is* the
   product.
3. **Re-plan cadence vs. map/voice thrash.** If the "next best turn" recomputes on every GPS tick,
   flip-flopping between two roughly-equal candidates produces exactly the kind of visible/audible
   churn that erodes trust (the same "erodes trust" language `CruiseVoicePolicy.swift:13-16` already
   uses to justify NOT narrating every restricted block). Needs a debounce/hysteresis rule analogous
   to `FinalApproachService`'s state-transition gating, not a naive "recompute on every fix" loop.
4. **What happens when the whole nearby area scores badly.** Neither the concept doc nor the PWA
   reference implementation defines a "there's nothing good here" state — `scoreEdgeCoverage` just
   returns low scores and the greedy walk picks the least-bad option anyway, silently. A driver being
   steered toward a "best available" option that's actually bad (all-metered, or restrictions starting
   in 10 minutes) without being told that's the reality is worse than no guidance at all. Needs an
   explicit low-confidence state and copy for it.
5. **Interaction with the existing Cruise Mode chrome (FT-18's Bottom Dock ruling, FT-20's sheet).**
   FT-18 explicitly isolated "End" away from routine-tap controls specifically to avoid an accidental
   tap in a moving car (`ContentView.swift:1893-1909`) and put "everything on the bottom." Any new
   guidance surface (a "next turn" line, a mini compass, a route hint) should extend
   `DriveModeBottomCard` rather than add new chrome, per that same "everything on the bottom"
   discipline — but that's itself a real design call requiring `@designer` review, not a given.
6. **Whether this needs new map chrome (a visible route polyline) at all.** A visible route/highlighted-block
   overlay is new `MapViewRepresentable` work — the second-most regression-prone file in the project
   per `HANDOFF.md`'s own file-contention notes (`build-18-sizing.md` §7's table), and every recent
   feature touching it has had to serialize because of that fragility. §7.2's recommended v1
   deliberately avoids this entirely (voice + card only, no polyline) for exactly this reason.
7. **This is judged by whether it actually finds a parking spot, and nothing except a real drive can
   test that.** No simulator run, no unit test, no `#if DEBUG` overlay (the exact tool that broke
   FT-20's six-round stalemate, `HANDOFF.md` 2026-08-22 entry) can verify "was that a good suggestion."
   Combined with Kevin being out of NYC for 1-2 weeks, this means the feedback loop on the one thing
   that actually matters here is calendar-slow, not session-slow. See §6.

---

## §6 — Sizing, calibrated honestly

**Calibration baseline, per this project's own recent history:** FT-15 (new backend-to-render
primitive) sized 4–6 sessions, landed in-band. FT-20 (new UI primitive, same worst-case files) sized
4.5–6.5 with an explicit "budget a follow-up round" warning and then ran to roughly **double** —
driven almost entirely by on-device iteration cost (six build-and-smoke cycles on one detent bug), not
code-writing. That overrun is applied here, not folded in as rounding error, exactly as
`build-18-sizing.md` did for its own estimates.

**Smart Sweep's iteration risk is structurally worse than FT-20's, for two reasons specific to this
feature:** (1) FT-20's bug was eventually findable by instrumentation — a `#if DEBUG` overlay solved
in one screenshot what four rounds of reasoning couldn't. **"Is this a good parking suggestion" has no
instrumentable ground truth** — it's a judgment call made by a human driving a car, not a measurable
property. (2) FT-20's iteration rounds were same-day, same-device. Smart Sweep's are gated on Kevin
being physically in Manhattan, and he's out for 1-2 weeks — the iteration tail is calendar-slow on top
of being open-ended.

### Code-writing estimate

| Work item | Sessions | Notes |
|---|---|---|
| `StreetGraph` model + loader (bundle `osm_oneway.json`, node/edge parse, nearest-node snap) | 1.5–2.5 | New primitive, no prior art on iOS (§2). Precedent-following pattern (`TileLoader`-style JSON parse) keeps this from being pure R&D. |
| Edge-to-blockface attachment + durability-weighted edge scoring (`scoreEdgeCoverage` analog) | 1–1.5 | Not a `ParkingProximityScorer` reuse (§3) — new function, modeled on but not copied from the PWA. |
| Greedy traversal core (revisit penalty, budget cap, loop-close OR destination-bias variant) | 1–1.5 | Destination-anchored variant is new design, not a port (§2). |
| Live guidance integration into Cruise Mode's existing voice/card loop (debounce, low-confidence state) | 2–3 | The genuinely new "experience" layer (§5 items 1–4). Scoped down substantially if §7.2's v1 slice is taken (no persisted route → no re-plan/thrash problem to solve). |
| Map overlay (suggested-route polyline, scanned-block highlight) — **only if in scope** | 1–1.5 | Touches `ContentView.swift`/`MapViewRepresentable.swift` (§5 item 6). Deferred entirely in §7.2's v1. |
| Tests | 1–1.5 | Graph parse, traversal, scoring — all pure-function-testable per this project's established pattern (`CruiseVoicePolicy`, `FinalApproachService`). |
| **Engineering subtotal** | **7.5–11** (v1 slice, no map overlay) / **9–14** (full concept, with overlay + destination anchor) | |
| QA | 1.5–2.5 | Higher than a typical feature's QA line because "does the suggestion make sense" isn't a checklist item — see below. |

### The iteration tail — the part that actually determines calendar time

**Not folded into the table above, on purpose, same discipline `build-18-sizing.md` applied to
`open_spot`'s claim mechanic and iCloud sync's merge case.** Budget **at least one full real-drive
iteration cycle** (retune revisit penalty / distance penalty / durability weights against how the
suggestions actually feel on real streets), and treat a second cycle as likely rather than a worst
case, given point (1) above (no instrumentable ground truth). Each cycle's calendar length depends on
Kevin's availability to drive it, not on engineering throughput.

### Total range this document would defend

**10–17 engineering+QA sessions for the v1 slice in §7.2 (algorithm core + Cruise Mode guidance
integration, no map overlay, no destination anchor), plus an iteration tail of at least 1, more likely
2+, full real-drive-and-retune cycles whose calendar length is set by Kevin's schedule, not
engineering capacity.** The full concept (persisted loop route, destination anchor, visible overlay,
coverage tracking across a multi-turn drive) is larger still — closer to `build-18-sizing.md`'s
original 10–20+ placeholder, now with the added confidence that the number is driven by real, named
work (the graph primitive, the destination-anchor redesign, the map overlay) rather than being an
uncalibrated guess. **This should not be scheduled as a single build regardless of which slice is
chosen** — same reasoning `build-18-sizing.md` §6 already applied, and the same "build 13 became
unshippable from landing too much at once" lesson `HANDOFF.md`'s 2026-08-19 checkpoint names directly.

---

## §7 — A staged path: what's the smallest version that's real and drive-testable on its own?

### §7.1 v1 framing recommendation (open decision — see below)

**Recommend: Smart Sweep v1 is not a new mode. It's Cruise Mode ("Find a Spot") gaining a second
voice/card line.** Today Cruise Mode says "Left side, free until 8pm. Right side, metered." v1 adds,
gated by the same cadence discipline `CruiseVoicePolicy` already enforces: **a directional hint** —
"Better odds ahead: left on Prince, about 2 blocks." No persisted route. No polyline. No coverage
tracking across the drive. Recomputed fresh at each qualifying GPS update using the new
`StreetGraph` + edge-scoring core (§6's unavoidable new primitive), evaluated only over the
handful of edges reachable from the driver's current node — closer to a live "hot/cold" compass than
a route.

**Why this framing, concretely, beats a from-scratch "Smart Sweep mode":**
- **Inherits Cruise Mode's already-shipped, already-specced ending (§1)** — "Park here" and "End" work
  unchanged. No new end-of-session UX to design.
- **Sidesteps §5's hardest problems.** No persisted route → no "route changes under you" problem
  (#2), no re-plan-cadence-vs-thrash problem in the route-invalidation sense (#3 still applies at the
  cue level but is a much smaller version of it), no map overlay → no `ContentView.swift`/
  `MapViewRepresentable.swift` risk (#6), no "sweep exhausted" state to design (§1's ending #3
  degrades to silence for free).
- **Reuses proven chrome** (`DriveModeBottomCard`, `CruiseVoicePolicy`'s cadence gate) instead of
  building new chrome, honoring FT-18's "everything on the bottom" discipline without a fresh design
  review cycle.
- **Is honestly drive-testable in one session's worth of driving**, unlike a full persisted loop
  route, which needs a drive long enough to actually close a loop to be evaluated at all.

**This is presented as a recommendation, not a ruling** — it's a real product framing choice (is this
a new "mode" the way the concept doc's own language implies, or an upgrade to an existing one) that
belongs with Kevin, not decided silently in a feasibility spec. See §7.4.

### §7.2 v1 scope, concretely

**In:**
- `StreetGraph` loader (bundled `osm_oneway.json`, node/edge model, nearest-node snap).
- Durability-weighted edge scoring, modeled on `scoreEdgeCoverage`, reusing the shared classification
  (`ParkingRulesEngine`) and skip-category set per §3.
- A "best next turn from here" query, evaluated over the driver's current node's outgoing edges only
  (no multi-step lookahead, no persisted path).
- One new voice/card line in the existing Cruise Mode loop, cadence-gated the same way
  `CruiseVoicePolicy` already gates block-change announcements.
- A low-confidence/no-suggestion fallback (§5 item 4) — silence, matching the existing
  all-restricted-block behavior.
- No new "start" action — lives entirely inside the existing "Find a Spot" flow.

**Out (explicitly, for v1):**
- Destination-anchored variant (§2 point 1) — current-location-only, same anchor Cruise Mode already
  uses.
- Persisted loop route / visible polyline / scanned-block highlight overlay.
- Cross-drive coverage tracking ("don't send me back to a block I already saw this session").
- Occupancy signal (concept doc's own v2, gated on Tier-3 `open_spot` — separate feature, separate
  gate).

### §7.3 v2 — the fuller concept, once v1 is drive-proven

Persisted greedy-walk route with visible polyline, coverage tracking across the session, loop-close
behavior, and the destination-anchored variant. This is where §5's harder problems (route
invalidation, thrash, map-overlay regression risk, "sweep exhausted" UX) actually have to be solved —
deliberately deferred past v1 so they're tackled only once the core scoring/suggestion quality is
proven to be worth the extra build risk on a real drive.

### §7.4 Open decisions for Kevin — surface before any code

| # | Question | Recommendation |
|---|---|---|
| OD-1 | **Naming (§0):** retire "patrol mode" — final user-facing + doc name? | Working name "Smart Sweep" for docs; user-facing copy is a `@designer` pass once §7.1 is settled, since it changes whether this needs a name at all (see OD-2). |
| OD-2 | **Framing (§7.1):** is this a new top-level mode, or Cruise Mode ("Find a Spot") gaining directional guidance? | Recommend the latter — inherits Cruise Mode's already-solved entry/exit UX and sidesteps most of §5's hard problems for v1. |
| OD-3 | **Realtime gate (§4):** does v1's no-occupancy scope actually need the realtime-solid gate, or is the gate prudential (general confidence in the live-data path) rather than a literal dependency? | Recommend honoring the gate regardless of the answer — but ask directly rather than assume, since the technical case for v1 needing it is weak on inspection. |
| OD-4 | **Anchor (§2):** is current-location-only acceptable for v1, deferring the destination-anchored variant (which has no reference implementation anywhere) to v2? | Recommend yes — the destination-anchored reward function is new design work with no prior art, and folding it into v1 roughly doubles the algorithm-design risk for a capability §7.2's slice doesn't strictly need to prove the concept. |
| OD-5 | **Scheduling:** given §6's range and the "don't bundle a big item into a build with small unrelated ones" lesson already applied once this cycle (`build-18-sizing.md` §6), should Smart Sweep v1 be its own dedicated build? | Recommend yes. |

---

## §8 — Out-of-scope follow-ups (noticed, explicitly punted, with rationale)

- **Occupancy-aware scoring (concept doc's own v2).** Gated on Tier-3 `open_spot` existing at all
  (reading (a) from §0) — a separate, smaller, already-scoped item (`build-18-sizing.md` §1a). Not
  re-litigated here.
- **Correcting `ParkingProximityScorer`'s doc comment** (§3) once Smart Sweep's real edge-scoring
  function exists, so the "score(near:) is the traversal's scoring function" claim doesn't mislead a
  future reader. Small, mechanical, belongs with whichever PR lands the real scoring function.
- **Multi-drive learning / personalization** (e.g., "you usually reject suggestions toward Ave B —
  weight it down") — not implied by anything in the concept doc or Kevin's framing; flagged only
  because it's the natural next request once v1 ships and shouldn't be assumed in scope.
- **Turn-ban-aware routing.** The concept doc (§8) already flags that the directed graph covers
  one-ways but not turn restrictions, and recommends the heuristic simply tolerate approximate
  routing. Not revisited here — same conclusion holds for the StreetGraph primitive in §6.
