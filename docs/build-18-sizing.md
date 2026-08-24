# Build 18 — Sizing

**Status:** Sizing exercise, not a spec. Written 2026-08-24 at Kevin's request, before any build-18
work is dispatched. Supersedes no prior doc — `docs/tier3-patrol-mode-buildplan.md`,
`docs/tier3-patrol-report-spec.md`, `docs/smart-parking-route-2.0-concept.md`, `docs/ft2-delete-own-pin-spec.md`,
`docs/open-items.md`, and `HANDOFF.md`'s changelog all stay as-is; this doc reconciles what they say
against what the code actually contains.

**Bottom line up front:** build 18 as currently described in `open-items.md` cannot be given one
honest number, because **the single biggest item in it — "patrol mode" — is an ambiguous term that
currently points at two different features**, one of which is ~85% already shipped and one of which
has never been specced. See §0. Until that's resolved, treat the two numbers in §0 as the range;
everything else (§1–§4) is priced independently and isn't blocked by the ambiguity.

---

## §0 — The load-bearing finding: "patrol mode" means two different things

`docs/open-items.md` (2026-08-19/20) describes build 18's patrol-mode item as *"patrol mode (5
sub-PRs, W8.5e–i, never estimated)"* and points at `docs/tier3-patrol-mode-buildplan.md`. I read that
doc, then verified its claims against the actual iOS code (per the task's explicit instruction to
verify rather than trust the plan). Two things are true at once:

**1. `tier3-patrol-mode-buildplan.md`'s "patrol mode" is not a route-finding feature — it was the
crowd-reporting UI (enforcement/sweeper reports), and Kevin killed the "mode" concept entirely on
2026-06-05** (`docs/tier3-patrol-report-spec.md` header: *"Kevin's product decision: NO separate
Patrol mode... two context-appropriate affordances replace the prior mode-gated design"*; confirmed in
`HANDOFF.md`'s 2026-06-06 changelog entry, *"DROPPED the separate 'Patrol mode.' Reporting is now
UNIVERSAL"*). What actually shipped under that doc's W8.5e/W8.5f labels:

| Sub-PR | Buildplan's W8.5 slot | Content | Status |
|---|---|---|---|
| #1 | W8.5e — anon auth + write path + vote path | `SupabaseAuthService`, `CommunityPinService.insertCrowdPin`/`upsertVote`/`callExtendPinExpiry` | ✅ **Merged** (PR #39, `d8917637`), refined by PR #41 (`ios/tier3-bug-fixes-batch1`) and PR #42 (instant feedback + periodic refresh) |
| #2 | W8.5f — patrol-mode UI surface / report flow | Long-press action menu, in-drive Report button, `ReportSheet.swift` | ✅ **Merged** (PR #40, `7da7ecac`), refined by #41/#42 |
| #3 | W8.5g — decay display (time-since badge, confirm-count badge) | `PinMarkerAnnotation.timeSinceBadge(pin:now:)`, `ReactionsRow`'s confirm-count text | ✅ **Verified present** in `PinMarkerAnnotation.swift:364` and `PinDetailSheet.swift:411` — the buildplan's own T3-3 ruling scoped decay to exactly this (no opacity fade, no separate countdown), and that scope is done |
| #4 | W8.5h — `open_spot` schema + iOS enum + claim mechanic | — | 🔴 **Not started.** No `.openSpot` case in `PinType` (`CommunityPin.swift:48-63`), no migration, no claim state anywhere in the codebase |
| #5–#6 | W8.5i — relevance-gated push + Drive Mode callout | — | ⚪️ **Explicitly deferred** by the buildplan itself (OQ-T3-4: "fast-follow... out of initial TF1 scope") — not blocking, not requested |

**So of the "5 sub-PRs, never estimated," three are done and verified in the running app, one is
explicitly out-of-scope-by-design, and exactly one (`open_spot`, §1a below) is real remaining work.**
That's a materially smaller item than "5 sub-PRs" implies.

**2. But `docs/drive-mode-scope-spec.md` (2026-05-18) ALSO used the label "patrol mode" — for a
completely different, never-built feature: a coverage-sweep / greedy street-graph route finder
(`PatrolModeService`, dynamic re-ranking on GPS update, opportunity voice cues, "I found a spot"
button, ~7.25 sessions estimated at the time).** `grep`/`git log` confirm no `PatrolModeService.swift`
or `PatrolView.swift` has ever existed on any branch. **This is the same feature described in
`docs/smart-parking-route-2.0-concept.md`** ("Parking Hunt" — coverage + durability orienteering
route) — and **`docs/ft20-bottom-sheet-navigation-spec.md` §0 OQ-4 cites both docs together as the
same upcoming thing**: *"Build 18's patrol mode inherits this vocabulary [the 'Find a Spot' rename]... the way it works in the future is to score parking nearby and direct the driver through the optimal
path (to find parking) nearby the target destination. That is already captured in
`smart-parking-route-2.0-concept.md`... and in `drive-mode-scope-spec.md`'s patrol mode (W8.5e–i)."*

**Given that the most recent product-direction language (FT-20's spec, written and Kevin-approved in
August) explicitly equates "build 18's patrol mode" with the coverage-sweep route feature — not the
already-shipped crowd-reporting one — meaning #2 is the more likely intended referent for "build 18
patrol mode."** But `open-items.md`'s own citation (`tier3-patrol-mode-buildplan.md`, "5 sub-PRs,
W8.5e–i") points at meaning #1. **These two source docs disagree with each other about which feature
build 18's "patrol mode" line item is.** This is not a nitpick — the two scenarios differ by roughly an
order of magnitude in size (§0a vs §0b below), and dispatching an engineer against the wrong one wastes
a full session before anyone notices.

**Recommendation: this is the first thing to resolve with Kevin, before any build-18 dispatch — not a
side note.** Ask directly: *"When you say build 18 includes patrol mode, do you mean (a) finish the
one remaining piece of the crowd-reporting feature — `open_spot` pins with a claim mechanic — or (b)
build the coverage-sweep 'smart route to find parking' feature that was conceptualized but never
specced against the current app?"*

### §0a — If "patrol mode" means (a): finish `open_spot`

This is real, bounded, already-specced-enough-to-estimate work. See §1a. **~2.5–4.5 sessions
including backend + QA.**

### §0b — If "patrol mode" means (b): the coverage-sweep smart parking route

**This cannot be sized as engineering work today, because it has never been specced against the
current app.** The only estimate that exists (`drive-mode-scope-spec.md`, ~7.25 sessions) is from
2026-05-18 — it predates Tier 3 crowd pins, the typed-pin schema, supabase-swift/realtime, and FT-20's
sheet, and its own proposed UI (`PatrolView`, `ActiveSheet.patrolMode`, a dedicated "mode") is exactly
the pattern Kevin rejected three weeks later when he killed "patrol mode" as a UI concept in the
reporting feature. Reusing that number would repeat the mistake FT-20 §11 warned about — scheduling
off an estimate that doesn't reflect the actual shape of the current codebase.

`smart-parking-route-2.0-concept.md` §6 itself lists *"a proper tech-lead feasibility spec (scoring
function, heuristic choice, detour-budget UX, integration with Mapbox/MapKit routing + the rules
engine) before any code"* as a hard gate. That spec doesn't exist yet. **If this is what Kevin means,
the honest next step is not "assign it a session count" — it's "spec it first,"** and that spec is
itself real work (comparable in scope to the FT-20 spec, which ran long and dense). Once specced, my
best-effort placeholder — treating it as a new-primitive feature in the FT-15/FT-20 size class, on a
codebase whose two most recent "honest" estimates for novel-UI work (FT-15: 4–6, FT-20: 4.5–6.5) both
ran to roughly double in practice — would put the *engineering* alone at **10–20 sessions**, before QA
and before the drive-test iteration this class of feature inherently needs (§4 in the concept doc:
*"budget for iteration on the scoring function with real drive data"*). That is bigger than any single
build this project has shipped. **It should not be folded into a build alongside iCloud sync and FT-2
regardless of what "18" ends up meaning as a label** — see §2.

---

## §1 — Per-item estimates

Sessions are iOS-engineering sessions unless noted, calibrated against this project's own history:
FT-15 (new backend-to-render primitive) sized 4–6 and landed in that band; FT-20 (new UI primitive,
same worst-case file) sized 4.5–6.5 with an explicit "budget a follow-up round" warning and then took
roughly double — driven almost entirely by *on-device iteration cost* (six build-and-smoke cycles on
one detent bug), not code-writing cost. That overrun is the standing calibration correction applied
below: **wherever a feature's correctness can only be judged on a real device/real behavior (not a
simulator, not a unit test), I've added iteration budget on top of the code-writing estimate, not
folded it in as a rounding error.**

### §1a — `open_spot` pins + claim mechanic (if "patrol mode" = §0a)

**What's actually left**, verified against the buildplan's own AC table (`tier3-patrol-mode-buildplan.md`
§6, AC-T3.8–T3.12):
- Backend: `ALTER TYPE public.pin_type ADD VALUE 'open_spot'` — non-transactional DDL, @backend-data
  writes the migration file, **Kevin applies to prod by hand** (standing rule). Trivial to write,
  ~0.25 session. Zero engineering risk; the risk is entirely in the "Kevin must remember to run it
  before the iOS code that depends on it ships" sequencing, same as every other migration in this
  project.
- iOS: `PinType.openSpot` case, 3-minute TTL branch in `insertCrowdPin`'s `expiresAt` switch, a new
  row in `ReportSheet.swift`, a "Heading there" claim button + locally-dimmed marker state (likely in
  `PinDetailSheet.swift`/`PinMarkerAnnotation.swift`), and the SOHO/LES zone guard (client-side check
  + server-side `zone_id` validation per AC-T3.12). This extends already-built, already-proven
  machinery (the report sheet, the insert path, the marker rendering) rather than building new
  machinery — closer in shape to W7's "per-pin toggle" extensions than to FT-15/FT-20's ground-up
  work.
- **The genuinely new part, and the one with real iteration risk: the claim mechanic is a new PRODUCT
  behavior, not just new code.** "Does dimming a claimed pin actually reduce two people racing for the
  same spot" is a live multi-user question, closer to patrol mode's own "judged by actually hunting a
  spot" framing than to a UI wiring task. It cannot be verified solo on one device — it needs two
  testers (or one tester + a manually-inserted second "claim" via curl) hitting the same pin. Budget a
  dedicated verification round for this, not a code-review pass.

**Estimate: 2–3.5 iOS sessions + 0.25 backend (migration file only) + 0.5–1 QA, plus one likely
follow-up round given the claim mechanic's live-behavior verification gate. Total ~2.5–4.5.**

### §1b — Coverage-sweep smart parking route (if "patrol mode" = §0b)

Not sizeable yet — see §0b. Flagged here as a placeholder, not a number Kevin should schedule against.

### §2 — iCloud parked-car sync

**Current state, verified:** `ParkPinService.swift` is a single-pin, single-device store —
`UserDefaults.standard`, `JSONEncoder`/`JSONDecoder`, a `wepark_parked_car` key, plus two Combine
publishers (`firstPinDropped`, `pinDropped`) that W6/W7.5 already subscribe to for notification and
Park-Until prompts respectively. `ParkedCar` already carries a `parkedAt: Date` field, which is a
usable last-write-wins tiebreaker — a real asset, not something that has to be invented.

**The mechanical swap** (`UserDefaults.standard` → `NSUbiquitousKeyValueStore.default`) is small,
maybe 0.5 session on its own — the API surface is nearly identical (`data(forKey:)` /
`set(_:forKey:)`, plus an explicit `.synchronize()` call).

**The real work, as Kevin already flagged, is the merge/conflict case, and it's underspecified right
now — not just un-built:**
- **No merge policy has actually been decided.** Last-write-wins by `parkedAt` is the obvious default
  and probably what Kevin wants (no UI, no login, per his own framing), but that's an inference by me,
  not a ruling. Silently picking a policy without surfacing it is exactly the kind of move this
  project's own specs repeatedly flag as a bad idea (FT-20 §12's "silently deciding X" pattern). This
  needs a 3-line OQ answered before code, not a de-facto decision buried in a PR diff.
- **What happens to the two Combine hooks on a *remote* change is a real product question.** If device
  B receives a sync update because device A parked a car, should device B's `pinDropped` fire (which
  today drives the W7.5 "Parking until when?" auto-prompt)? Almost certainly not — that prompt should
  only fire from a *local* drop — but that's a guard that has to be deliberately added, not something
  the mechanical swap gives you for free.
- **`NSUbiquitousKeyValueStoreDidChangeExternallyNotification`'s reason codes need distinct handling**:
  `ServerChange`/`InitialSyncChange` (a real remote update — apply the merge policy),
  `AccountChange` (user switched iCloud accounts — arguably should NOT silently merge stale data from
  a different Apple ID), `QuotaViolationChange` (irrelevant at this payload size, but worth a one-line
  guard so it doesn't silently corrupt state if ever hit).
- **This is untestable in the sandbox and awkward even on Kevin's single Mac.** Real verification needs
  two physical devices signed into the same iCloud account, or a device + simulator pair sharing an
  account — logistically closer to FT-20's "two simultaneous simulator sessions" verification note
  than to a normal single-device smoke. Sync also has its own latency/timing behavior (not instant,
  not deterministic) that a single quick smoke may not exercise the way a real multi-day, multi-session
  usage pattern would.

**Estimate: 2–3 iOS sessions (0.5 mechanical swap + 1.5–2.5 conflict-policy design and implementation)
+ 0.5–1 QA, and — same reasoning as §1a's claim mechanic — budget one likely follow-up round given the
dual-device verification gate is a real analog to FT-20's detent-class problem: a behavior class that
can silently look fine in a quick single-device check and only reveal itself under real multi-device
timing. Total ~2.5–4.**

### §3 — FT-2 delete-own-pin

**Backend finding that changes this item's risk profile: the spec's OQ-1 ("verify or apply the RLS
delete policy") is very likely already resolved with zero migration needed.** I checked
`supabase/02-pins-schema.sql` directly (not just the spec's description of it):

```sql
-- 02-pins-schema.sql:157-159
drop policy if exists pins_delete_own on public.pins;
create policy pins_delete_own on public.pins
  for delete using (auth.uid() = author_id);

-- 02-pins-schema.sql:166
pin_id uuid not null references public.pins(id) on delete cascade,
```

Both the RLS policy and the cascade FK the spec asks Kevin to verify are **already present in the
committed schema file**, not something that needs to be written. Stronger evidence this is already
live in production: `supabase/02f-block-scoped-restrictions.sql` (the FT-15 schema, applied to prod
per `HANDOFF.md`'s FT-15-complete changelog) references `pins_delete_own` four separate times as *"the
existing, unmodified `pins_delete_own` policy"* — i.e., a later migration already depends on it being
live. **Kevin's §3.1 verification step (two 30-second SELECT queries) should still be run before
merging to be certain, but the honest expectation is that it passes clean and §3.2's SQL is not
needed.** This is a smaller, lower-risk item than the spec (written before this was confirmed)
frames it as.

**What's actually missing, verified against the code:** `CommunityPinService.swift` has no
`deleteCrowdPin` method (grep confirms), and `PinDetailSheet.swift` has no delete UI, no confirmation
dialog, no "trash" affordance (grep confirms zero hits). This is purely iOS work now — one new service
method + one UI addition to an existing, working pattern (`ReactionsRow` already handles the
`isOwnPin` branch, just dead-ends it today).

This is also, by a wide margin, the **lowest product-behavior-risk item in build 18.** It's not judged
by "does it feel right while driving" or "does it actually prevent a race" — it's judged by "does
tapping delete work," which unit tests and a single on-device smoke can verify directly. The spec
(`docs/ft2-delete-own-pin-spec.md`) is unusually complete: 8 unit tests inventoried, 15 ACs, explicit
edge-case handling (offline, double-tap, already-expired pin), and an explicit call-out that there's
no parallelization benefit — it's a single small PR.

**Estimate: 1–1.5 iOS sessions + 0.5–1 QA. Total ~1.5–2.5.** The cheapest, most de-risked, most
shovel-ready item in build 18.

### §4 — Six stability fixes (badge, sheet radius, zoom-out crash, zoom lock, compass, out-of-coverage guard)

Per the task's framing, these are already merged or in PR #89 and smoke-tested — **0 additional
sessions.** (Verified PR #88, "badge never clears + browse sheet corner-radius mismatch," is merged at
`747f1e90` with a QA MERGE verdict — consistent with "already built.") Not re-litigated here.

---

## §5 — Total range

| Scenario | Items | Range (sessions) |
|---|---|---|
| **"Patrol mode" = §0a (finish `open_spot`)** | open_spot (§1a) + iCloud sync (§2) + FT-2 (§3) + stability fixes (§4, done) | **6.5–11** |
| **"Patrol mode" = §0b (smart parking route)** | route feature (§1b, needs its own spec first — 10–20+ once specced) + iCloud sync (§2) + FT-2 (§3) + stability fixes (§4, done) | **~14–26+**, and the low end assumes the spec itself is free, which it isn't |

Both numbers include one realistic follow-up round for the items that have a live-device or
multi-user verification gate (§1a's claim mechanic, §2's dual-device sync), consistent with this
project's own most recent calibration lesson: FT-20's "honest" 4.5–6.5 estimate still missed the
on-device iteration tail and came in around double. I did not apply a blanket 2× multiplier to
everything — only to the items that share FT-20's actual failure shape (a behavior that can't be
fully verified except live, on real hardware, across a real interaction).

---

## §6 — Split recommendation

**Recommendation: split, in both scenarios — and the split line is the same one regardless of which
"patrol mode" Kevin means.**

**iCloud sync (§2) and FT-2 (§3) are small, independently well-specced, touch disjoint files from
each other, and have no dependency on patrol mode.** Combined they're **~4–6.5 sessions** — right in
the FT-20-class size band for a single build, and neither carries anything close to FT-20's UI-novelty
risk. These two can ship as their own build cycle quickly and cleanly.

**Whichever "patrol mode" turns out to mean, it does not belong bundled with those two:**
- If it's §0a (`open_spot`, ~2.5–4.5), bundling it *would* fit inside a build-17-sized envelope
  (§0a + §2 + §3 ≈ 6.5–11, comparable to FT-20 alone in the worst case) — but it still shares two
  files (`CommunityPinService.swift`, `PinDetailSheet.swift`) with FT-2, which means it can't run
  fully parallel with FT-2 even though it's small (see §7). Folding it in is defensible but not free.
- If it's §0b (the coverage-sweep route), **bundling it repeats build 13's exact failure shape at a
  larger scale.** Build 13 became unshippable from landing too much at once on a build that was
  already sizeable; §0b alone is a bigger, less-specced item than build 17's entire FT-20 payload was,
  dropped into a build that also contains two unrelated small items. This is the clearest "say so
  plainly" case the task asked for: **if "patrol mode" means the smart parking route, build 18 as
  currently scoped is not one build — it's at minimum a spec cycle plus what would likely become
  builds 18 and 19.**

Kevin has already decided to fold things into 18 rather than pre-split by feature category, and I'm
not re-arguing that general call. What I am flagging is that **the number attached to "18" depends
entirely on the §0 disambiguation**, and one of the two possible answers produces a build large enough
to warrant the same split Kevin himself already applied once this cycle (pulling patrol mode out of 17
for exactly this reason, per `HANDOFF.md`'s 2026-08-19 checkpoint: *"Patrol mode is a different product
behaviour... Build 13 became unshippable because too much landed at once"*).

---

## §7 — Sequencing and parallelism

**This VPS has 2 cores — 1–2 agents concurrently, not more (per standing note in `open-items.md`).**
`ContentView.swift` and `MapViewRepresentable.swift` remain the two most regression-prone files and
have serialized every recent feature (FT-17a → FT-18 → FT-15 → realtime → FT-20, in that order,
one at a time). None of build 18's small items (§2, §3) touch either file — that's worth using.

| Item | Files touched | Contends with |
|---|---|---|
| iCloud sync (§2) | `ParkPinService.swift`, tests | Nothing in this build. Fully disjoint. |
| FT-2 (§3) | `CommunityPinService.swift`, `PinDetailSheet.swift`, tests | `open_spot` (§1a), if run concurrently |
| `open_spot` (§1a, if pursued) | `CommunityPinService.swift`, `ReportSheet.swift`, `PinMarkerAnnotation.swift`, `PinDetailSheet.swift`, possibly `ContentView.swift` (zone guard) | FT-2 on two files; also touches `ContentView.swift` if the zone_id guard needs a UI-level check |
| open_spot backend migration | new `.sql` file only | Nothing — independent, Kevin-applied whenever ready |
| Smart parking route (§1b, if pursued) | `RouteService.swift`, `ContentView.swift`, `MapViewRepresentable.swift` (near-certain — any route/sweep overlay needs the map layer) | Everything. Cannot run parallel to anything else touching those files, and per this file's own history should not be attempted alongside another large `ContentView.swift` change. |

**Recommended order, given the 2-core ceiling and the §6 split:**
1. **iCloud sync and FT-2 in parallel** (2 agents, genuinely disjoint files) — the fast, low-risk pair.
2. **Then `open_spot`** (if that's what "patrol mode" means), serialized after FT-2 specifically
   because of the two shared files — not because of core count. Its backend migration can be written
   and queued for Kevin at any point in parallel with anything.
3. **The smart parking route, if that's what "patrol mode" means, is its own spec-then-build cycle,
   not slotted into this sequence at all.** Don't schedule an agent against it until §0 is resolved
   and, if it resolves to §0b, until a fresh feasibility spec exists.

---

## §8 — Risk register

**1. The §0 naming ambiguity, unresolved.** By far the largest risk in this document — not a coding
risk, a scoping risk. Dispatching against the wrong meaning wastes a full session before anyone
notices, and the two meanings differ by roughly an order of magnitude. **Must be resolved with Kevin
before any build-18 engineering is dispatched.**

**2. The realtime "solid" gate has not been met yet, and it gates patrol mode specifically (either
meaning).** Per `HANDOFF.md`'s most recent changelog entry (2026-08-22): *"NEXT: Kevin archives 17 →
TestFlight → drive test. That drive is also the gate on build 18 (patrol mode), which must not start
until realtime has been proven on a live socket in Manhattan."* Nothing in this doc's research found
evidence that drive has happened. **iCloud sync and FT-2 have no such dependency and can start
immediately; `open_spot`/the route feature cannot start until Kevin confirms the drive-test result.**

**3. iCloud sync's conflict/merge policy is a real, unmade product decision being treated as an
implementation detail.** The engineer will either invent a policy silently (bad pattern, repeatedly
flagged in this project's own specs) or stall waiting for an answer that was never explicitly asked
for. Surface the 3-line question — "last-write-wins by `parkedAt`, silently, no UI, correct?" — before
dispatch, not after.

**4. Two items in this build share the same class of risk FT-20's six-round bug exemplified: a
behavior that looks locally correct and only fails under real, live, multi-actor conditions.**
`open_spot`'s claim mechanic (does it actually stop two people racing for a spot?) and iCloud sync's
merge case (does it actually converge correctly across two real devices with real sync latency?) are
both this shape. Neither can be fully verified by a single engineer on a single simulator run, the way
FT-2's delete button can. **Budget the follow-up round for these specifically — don't let a green
build + one quick smoke stand in for verification the way it didn't for FT-20's peek detent.**

**5. File contention between `open_spot` and FT-2** (`CommunityPinService.swift`,
`PinDetailSheet.swift`) means they cannot be dispatched as a naive "2 agents, 2 cores" pair without
coordination — the instinct to parallelize everything that fits in 2 cores would recreate exactly the
kind of silent collision this project's memory already flags (*"Engineering sub-agents can hijack
orchestrator commits onto the wrong branch"* / general file-contention notes in `open-items.md`).

**6. If §0b (smart parking route) is what's meant, folding it into "build 18" as a label risks Kevin
scheduling against the small-scenario number in §5 by mistake**, since both scenarios currently share
the same build number in the planning docs. Recommend giving the two scenarios distinct working names
(e.g., "18 — cleanup" vs. "19 — smart route") the moment §0 is resolved, so the size difference is
visible in the project's own tracking, not just in this doc.

---

## §9 — What to tell Kevin, in order

1. **Answer §0 first: which "patrol mode" did you mean for build 18** — finishing `open_spot`
   (small, ~2.5–4.5 sessions, mostly done already) or the coverage-sweep smart parking route
   (unspecced, and by your own concept doc's rule needs a feasibility spec before any code)?
2. **iCloud sync and FT-2 are the fast, low-risk pair** — ~4–6.5 sessions combined, no shared files,
   can start today regardless of the §0 answer or the drive-test gate.
3. **Confirm the iCloud merge policy** (last-write-wins by save time, no UI, silent) before that
   engineer starts, so it isn't invented mid-PR.
4. **FT-2's backend step is very likely a 30-second no-op, not a migration** — the RLS policy and the
   votes cascade are already in the committed schema and referenced as live by a later migration. Run
   the two verification queries to be sure, but don't expect to write new SQL.
5. **`open_spot`/the route feature both wait on your build-17 drive test** proving realtime holds —
   that gate hasn't been cleared yet as of the last changelog entry.
