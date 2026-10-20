# Drive Mode as the default opening experience — destination-less Cruise home screen

**Status:** Spec draft, 2026-10-19; **amended 2026-10-20 — goal-first parking is now the
centerpiece (§0.8).** Not started. Kevin's ruling on §0's decision list AND §0.8's five "open
decisions for Kevin" is required before any engineering is dispatched — this is the opening screen
for 100% of users, the highest-blast-radius UI change in the project's history.
**Author:** @tech-lead
**Locked premise (Kevin, 2026-10-19 — do not re-litigate):** "make drive mode the default and more
intuitive — it's by far the best and easiest use case, should arguably be the opening page." Kevin
chose **destination-less Cruise**: open the app → already heading-up [posture TBD by §0.1], your
location, live curb colors around you, no destination required, with "parking near me" as the
ambient/optional action.
**Supersedes:** nothing outright. **Demotes** the FT-20 browse sheet from default-mounted to
pull-up (§0.4) — the sheet's content, detent math, and search machinery are reused, not deleted.
**Touches/reconciles:** `docs/cruise-mode-spec.md` (shipped — the escalated Cruise session this
spec reuses verbatim), `docs/longpress-universal-plant-spec.md` (spec-first, not started —
sequencing note in §0.7), `docs/patrol-mode-feasibility-spec.md` (feasibility-only, not started —
§0.7 reinforces its own §7.1 recommendation), open item #18 (overnight nudge, not started —
re-targeting note in §0.7).
**HANDOFF reference:** `HANDOFF.md` line 206, 2026-10-19 changelog entry — "NEW DIRECTION (Kevin,
2026-10-19): make Drive Mode the default/opening experience — under discussion, spec pending." This
is that spec.

---

## AMENDMENT — 2026-10-20: goal-first parking is this spec's centerpiece (LOCKED)

**Locked (Kevin, 2026-10-20 — do not re-litigate):** one day after this spec's first draft, Kevin,
driving, reframed the whole premise. The 5-color curb palette answers "what's legal right now" —
but the real NYC job is intent: *"a spot that's free tonight AND tomorrow, don't move it."* The
ambient home screen's centerpiece is **no longer a generic "Find a Spot" pill. It is a huge,
unmistakable goal selector** — the user declares what they want, the map collapses to answer that
one question. Captured live as `docs/open-items.md` **#35**, which directly subsumes and
re-targets **#18** (night "sea of green" — every curb reading green at dusk, exactly when a driver
needs "free until 8am" vs "free for days" and can't tell which). This amendment implements both,
not just references them — their rows should close once this ships.

**Second locked refinement (Kevin, same day, mid-build correction):** pure "park overnight" is a
**non-goal** — in most of Manhattan you can trivially park overnight free almost anywhere; that's
not the hard job. **The hard, valuable job is surviving tomorrow MORNING's ASP side-swap without
having to move the car.** A car left Monday night on a Tue/Fri-cleaned side must move Tuesday 8am
(bad); the same car on a Mon/Thu side is clear through Tuesday and Wednesday into Thursday (good —
that's the spot). **"Free overnight" must filter on "does NOT have to move for tomorrow's sweep,"
not on a naive "legal until some clock hour" window.** **§0.8** below (a new decision block,
appended after the original §0.7) bakes this in from the start — it replaces §0.1's "ambient
primary affordance" bullet (edited in place, below) and ripples into §0.4a, §0.6, §0.7, §2, §3.3,
§4, §5, §6.

**The engine is 90% already built, not 100%.** `ParkingRulesEngine.isFree(segment:from:until:)`
(`ParkingRulesEngine.swift:659`) already walks ASP suspension dates (`:704`) and metered billing
hours (`:649-650`, `:749-762`) correctly — it is **not** subject to the `nextRestriction()`
metered-skip bug open item #18 flagged as a prerequisite (`HANDOFF.md`'s 2026-09-12 My Car sheet
entry, PR #106 QA Finding #1) — that bug lives in a different function (`nextRestriction`, used for
status-line labels), not in `isFree()`, which Park Until and goal-first both use for the actual
yes/no filter. `ContentView.swift`'s `parkUntilMode`/`parkUntilTarget` state and its binary
green/red `rebuildOverlays()` branch (`:1921-1973`) already express exactly "filter the map to one
yes/no question for a window." **What's genuinely new, scoped precisely in §0.8.4:** a small,
additive parameter on `isFree()` so "Free overnight" and "Park & forget" can ask "would I have to
*move* the car" (ignoring metered payment, which doesn't force relocation) rather than "is this
curb unrestricted AND unpaid" (today's strict semantics, correct for "Free a few hours," wrong for
the overnight family). This is the one real new piece of engine surface this amendment requires —
call it out honestly in sizing (§4), it is not a free client-side relabeling exercise.

**Kevin's rulings on the five open decisions (2026-10-20 session — 4 of 5 LOCKED):**
1. **Park & Forget ladder — RULED, confirmed with corrected labels.** Kevin's instinct ("no such
   thing in NYC as >2 days unless over the weekend") was checked against the shipped tiles (all
   46,925 segments): among parkable segments WITH a weekly move-forcing rule, 45.6% max out at
   exactly 3 consecutive clear days (the Thu→Mon weekend gap on Mon/Thu-style sides), 45.3% at
   1–2 days (Mon–Sat/Mon–Fri commercial), and — the part Kevin's neighborhood doesn't have —
   9.2% (2,888 segments) are genuine once-a-week sweep sides clearing ~6 days, plus another 9.2%
   of parkable curb has NO weekly move-forcing rule at all (metered-only/unregulated — clears any
   window once meters are ignored). So the top rung is real (~17% of parkable curb), and the
   middle rung IS the weekend gap. **Rungs locked as `offsetDays: 8 → 4 → 2`, which in full clear
   days is 7 → 3 → 1** — the original draft's "7d → 4d → 2d" labels were sloppy offsetDays
   shorthand; implement to the offsets, describe to users in "Good through <day>" terms only
   (§0.8.3a), never rung numbers. Kevin, ruling: "Okay fine go for it," reaffirming that
   **overnight-into-next-day is the flagship use case** — consistent with Free Overnight being the
   pre-selected default (§0.8.1, unchanged).
2. **"Free a few hours" = +3h — RULED, confirmed** ("sure good idea"). §0.8.5 as written.
3. **Single flag vs two — RULED: ONE FLAG** (`driveModeDefaultEnabled`, both halves together,
   per §0.6's recommendation). Locked 2026-10-20 under Kevin's same-day autonomy directive
   ("limit confirming steps... run autonomously, only truly vital questions") after two
   explanations drew no objection and his "I think goal first makes sense" aligned with the
   recommendation's rationale (an ambient screen without its goal-first payload is a pointless
   halfway state). Veto-able by Kevin any time before the flip build — flipping is a separate,
   later, Kevin-gated decision regardless.
4. **Icons/copy — RULED: @designer owns it**, with a NEW LOCKED CONSTRAINT from Kevin: *the goal
   buttons must be huge and unmistakable — "anyone who boots it up should get it. Maybe not the
   ASP rules but at least get the buttons."* First-time comprehension with zero NYC-parking
   jargon is the design bar; these are the biggest tap targets in the app (extends Kevin's
   standing bigger-touch-targets preference, PR #110). AC-31's no-evasion-language constraint
   unchanged.
5. **"Free a few hours" metered tolerance — RULED: strict confirmed** (Kevin: "it's a meter so
   that's not free"). §0.8.5 unchanged; the §6 metered-tolerant variant stays punted.

---

## Read this first — the single biggest risk

**Today, one boolean (`driveModeActive`) gates two unrelated things at once: (1) the escalated
windshield posture (continuous navigation-grade GPS, heading-up camera, voice, wake lock) and (2)
whether long-press-to-plant and the resting browse interactions are even reachable** (`handleLongPress(at:)`
early-returns when `driveModeActive == true`, `ContentView.swift:4272`). **If this spec's
implementation collapses "Cruise is now the default screen" into "`driveModeActive = true` by
default," every cold launch — including someone checking a block from the couch — silently inherits
continuous best-for-navigation GPS, a disabled idle timer (`LocationService.swift:198-201`), a
heading-up camera, and a disabled long-press-to-plant, 100% of the time, for every user, forever.**
That is a battery and disorientation regression at launch scale, not a corner case, and it directly
fights the long-press-universal-plant direction Kevin approved one build ago. The entire
architecture recommended below (§3.1's two-posture split) exists specifically to prevent this. Any
engineer picking this spec up should re-read this paragraph before touching `ContentView.swift`.

---

## §0 — The decision list (Kevin rules; recommendations attached)

### 0.1 — Destination-less Cruise, concretely: what's on screen at cold launch

**Recommendation: the home screen is the map itself, at rest — not an escalated Drive Mode
session.** Concretely, on cold launch:

**Present, unconditionally (reusing shipped code, zero new logic):**
- The user's location as the existing default blue dot (`showsUserLocation = true`, shipped since
  W5.1) — **not** the directional drive chevron (that custom `MKAnnotationView` only mounts when
  `driveModeActive == true`, per W8.5c-polish PR-2's `mapView(_:viewFor:)` intercept — no change
  needed, the chevron correctly stays drive-only).
- Live 5-color curb overlays, auto-centered on the user via the existing viewport-polish 3-priority
  logic (`ContentView.swift:3717-3751`: deep-link → cached-fix-in-coverage snap → request-then-wait
  → `manhattanCenter` fallback). **The 5-color severity palette
  (`docs/design/ios-mvp-palette.md` Option B) is unchanged — sacred, not touched by this spec.**
- The ASP suspension banner (`ASPBanner`, `ContentView.swift:2037`) if applicable — unchanged.
- The persistent Report pill + "?" map-key button (`communityMapChromeVisible`,
  `ContentView.swift:2253`) if `AppConstants.communityEnabled` — unchanged.
- The My Car marker (blue circle, tentative/parked states) if a car is currently parked — unchanged.
- **~~One ambient primary affordance: a single "Find a Spot" pill~~ — SUPERSEDED, 2026-10-20 (§0.8).**
  The original draft put a single generic pill here, calling `enterCruiseMode()` on tap. **Kevin's
  2026-10-20 ruling replaces this with the goal-first selector as the screen's primary, centerpiece
  affordance** — three large goal buttons, not one generic one. Full mechanics, exact time windows,
  and how the old escalation trigger survives (demoted, not deleted) are in **§0.8**. This bullet is
  struck through rather than deleted so the "what came before" history isn't lost — see §0.8.7 for
  the demoted escalation entry point and §0.8.8 for the full-palette toggle this ambient screen also
  needs.

**Absent vs. today's FT-20 browse sheet default:**
- No persistent bottom sheet mounted by default. No search field competing for the first glance.
  No "New to parking?" link visible until the user pulls up search (§0.4).
- No heading-up rotation, no auto-zoom/tilt, no `.mutedStandard` map style, no voice, no wake lock —
  all of those remain exactly what they are today: consequences of `driveModeActive == true`, which
  stays `false` at rest (§3.1).

**Must NOT:**
- Auto-start voice guidance. Voice only ever fires inside an escalated Cruise session
  (`CruiseVoicePolicy.shouldAnnounce`, gated on real block context — `docs/cruise-mode-spec.md`
  §4.2) — never at rest, never "to nowhere." Unchanged by this spec.
- Nag. No forced onboarding gate blocks the map. The one first-launch location-priming moment
  (§0.2) is a one-shot, dismissible card, same pattern as `BackgroundNoteGate`
  (`ContentView.swift:3468-3472`) — shown once, never again, regardless of the user's choice.

### 0.2 — Cold-launch cost + permissions (the riskiest part of this spec)

**Recommendation: do not request location permission more eagerly than today's lazy pattern — add
exactly one new, one-shot, dismissible priming card, and fix a real pre-existing gap this change
newly exposes.**

**What stays unchanged (reused, not rebuilt):** the viewport-polish auto-center logic already only
calls `requestAndFetchLocation()` when the user is already authorized (Priority 2b,
`ContentView.swift:3744-3748`) — it never silently fires the system permission prompt on a fresh
install. Cold launch for a never-asked user already falls through to `manhattanCenter` with zero
permission prompt today, and this spec keeps that behavior. **"It grabbed my location immediately"
is not a new risk this spec introduces** — it's a risk only if the engineer adds an unconditioned
permission request where none exists today.

**What's new:** a one-time dismissible card (NOT a blocking alert), shown only when
`locationService.authorizationStatus == .notDetermined` on the first-ever home-screen render,
gated by a new one-shot `UserDefaults` key following the exact `BackgroundNoteGate` convention
already in this codebase (`ContentView.swift:3468`). Copy: something like "See real parking
conditions around you — allow location." "Allow" calls `requestAndFetchLocation()` (fires the real
system prompt). "Not now" dismisses and never shows again. Denying at the system level or
dismissing the card both fall through to the degraded-but-functional state below — never a dead end.

**A real gap this spec must fix, not just work around:** `LocationService.startDriveMode()`
(`LocationService.swift:181-202`) assumes authorization is already granted — it calls
`manager.startUpdatingLocation()`/`startUpdatingHeading()` directly and never calls
`requestWhenInUseAuthorization()`. Today this is masked because the only way to reach
`startDriveMode()` is via Drive Mode's existing entry points, and in practice a user has usually
already triggered `requestAndFetchLocation()` via the recenter button first. **Once the ambient
"Find a Spot" pill becomes the primary, first-touch affordance in the app, a user who dismissed the
priming card (or who never saw it, pre-this-change) can tap it while still `.notDetermined` and get
silent nothing** — no prompt, no error, no parking commentary, no visible cause. **Fix: `enterCruiseMode()`
must check `locationService.authorizationStatus` and route through `requestAndFetchLocation()`
first when `.notDetermined`, before calling into the `driveModeActive = true` escalation.** This is
required, not optional polish — it is the direct consequence of promoting Cruise to the primary tap
target.

**Denied/restricted fallback, graceful:** map stays on `manhattanCenter` or last-known cached
position; curb-color coverage does not depend on location (same as today — the user can pan/zoom
anywhere and see rules); the ambient pill's label/subtitle changes to something like "Enable
location to find parking near you" with a tap-through to Settings (`UIApplication.openSettingsURLString`);
search, long-press-to-plant, and the Report pill all continue to work fully — none of that is
location-gated today and this spec does not change that.

**Battery/render posture — the load-bearing guardrail:** the ambient home screen at rest uses ONLY
the existing single-shot/coarse posture (`requestLocation()`-class fix,
`kCLLocationAccuracyHundredMeters` — the non-drive branch of `LocationService`, unchanged). It does
**not** call `startDriveMode()` (continuous `kCLLocationAccuracyBestForNavigation`, `distanceFilter
= kCLDistanceFilterNone`, `activityType = .automotiveNavigation`, `pausesLocationUpdatesAutomatically
= false`, wake lock `isIdleTimerDisabled = true` — `LocationService.swift:188-201`) until the user
explicitly taps the ambient pill (Phase 1) or real motion is detected (Phase 2, §0.5). **This is the
single concrete mechanism that prevents the "biggest risk" paragraph above from happening in
practice** — call it out as a named invariant in the PR description and in QA's checklist, the same
way the #31 camera-mutation invariant gets called out in every Drive-Mode-adjacent PR today.

### 0.3 — The couch/non-driver case

**Recommendation: there is no separate "browse mode" to maintain — the resting posture of the one
home screen already IS the couch-safe experience,** because §0.1/§0.2 already keep `driveModeActive
== false` at rest. A user opening the app from home sees a north-up (or last-oriented) map, curb
colors, their last-known-ish position, and nothing that looks or behaves like a windshield UI — no
heading rotation, no tilt, no voice, no muted map style. Panning, pinching, tapping a block for
detail, and long-pressing to plant a report or a parked-car pin all work exactly as they do in
today's flag-on resting experience (`longpress-universal-plant-spec.md`'s entire design assumes
this posture and is unaffected — see §0.7). There is no "demote the drive chrome" step needed
because drive chrome was never mounted in the resting posture in the first place — Cruise's ambient
value (ambient ≠ active) is visible at a glance; the full escalated session is one deliberate tap
(or, later, one detected motion) away.

### 0.4 — FT-20 browse sheet's fate: demote, don't retire

**Recommendation: demote to a pull-up, not retired.** The sheet's substance — `BrowseSheetDetentMath`'s
pure peek/medium height computation, `BrowseSearchAreaView`'s search field + trailing-edge
`gearshape` Settings affordance, the "Find a Spot" primary button, the "New to parking?" link — is
reused unchanged. What changes is presentation state, not content:

- `@State private var activeSheet: ActiveSheet? = .browseNav` (`ContentView.swift:483`) → default
  becomes `nil` under the new flag (§0.6). The home screen genuinely shows no sheet at cold launch.
- `dismissTargetOutsideBrowseNav` (`ContentView.swift:1248-1251`, currently resolves to `.browseNav`
  whenever not driving/not block-selecting) must change in the same breath — otherwise cold launch
  looks sheet-free but dismissing a block-detail or pin-detail sheet snaps the user straight back
  into the full `.browseNav` sheet, a jarring inconsistency between "how I arrived" and "how I land
  after any interaction." Both the initial `@State` and this rest-state target must flip together,
  or this ships half-converted.
- A nice simplification this unlocks: `enterCruiseMode()`'s `noBlockingSheetPresented` guard
  currently special-cases `.browseNav` as equivalent to `nil` (`ContentView.swift:3029-3035`,
  comment explains this exists only because `.browseNav` WAS the rest state). Once the rest state
  is genuinely `nil` again, that special case can likely be deleted — flag for the implementing
  engineer to verify and simplify, not assume.
- **Reachability:** add a small, always-visible persistent "Search" icon affordance (same family as
  `recenterButtonStack`'s 44×44pt `.regularMaterial` circles, bigger-touch-target convention) that
  presents `.browseNav` at its `.medium` detent on tap. This is the mitigation for the tap-count
  regression below (§0.4a) — without it, Job B gets strictly worse.
- The sheet's own `.presentationBackgroundInteraction`/`.interactiveDismissDisabled` configuration
  currently assumes `.browseNav` is permanently present and non-dismissible at rest (FT-20's whole
  design point). That assumption flips too: the sheet becomes a normal, dismissible, on-demand
  sheet like every other `ActiveSheet` case. **This is real engineering work, not a one-line default
  change** — size it accordingly in §4.

#### 0.4a — Tap counts, old vs. new, for the two core jobs

| Job | Old (sheet default-open) | New (ambient pill default, sheet pulled-up) |
|---|---|---|
| **A — "hunt a spot where I am now"** | Sheet already open, competing with search field for attention → tap "Find a Spot" (1 tap, but curb colors are partially obscured by the sheet until that tap) | **AMENDED (§0.8):** map already shows the Overnight-filtered answer at cold launch, zero taps, zero obstruction — the common case needs no tap at all. Switching to a different goal, or to full-palette, is 1 tap. **Net: zero-to-one tap, strictly better than the base spec's already-good "same tap count" claim** — this is the literal centerpiece Kevin asked for, not just a glance-value improvement. |
| **B — "navigate to a destination then park"** | Sheet already open → tap search field → type/select destination → Start (search reachable in 0 extra taps) | Tap the new persistent Search icon (+1 tap) → search field → type/select → Start | **Net: +1 tap for Job B**, specifically because the search entry point is no longer sitting open by default. The persistent Search icon (§0.4) is the recommended mitigation, bringing it back to parity with today (1 tap to reveal search, same as before — just a dedicated icon instead of an already-open sheet). **Flagging this honestly rather than hiding it: without the persistent Search icon, Job B regresses; with it, Job B is tap-count-neutral.** |

### 0.5 — Motion-awareness: should Cruise auto-escalate?

**Recommendation: yes, eventually — but as its own later phase, not bundled into this spec's v1.**
Rationale: a driver circling for parking with their phone mounted should not have to remember to tap
anything; the app should notice motion and escalate into the full heading-up/voice posture on its
own, then de-escalate back to ambient when stopped for a while. This is new logic — no existing
service in this codebase currently answers "has the user started driving," and it deserves the same
pure-function, hysteresis-gated, unit-tested treatment this project already applies to adjacent
problems (`FinalApproachService`'s distance-threshold state machine, `CruiseVoicePolicy`'s
announce-gating, `LocationService.selectDriveHeadingSource`'s speed-gated branch at
`LocationService.swift:67-86` — the precedent pattern, not literally reused code). Concretely:
sustained speed above a walking threshold (something above 0.5 m/s — that constant is tuned for
"stay live while crawling for parking," not "distinguish walking from driving," a different
question) for several consecutive fixes over ~10-15 seconds before auto-promoting to
`driveModeActive = true`/`.cruise`; a longer stillness window (60-90s) before auto-demoting back to
ambient, so it doesn't flap at a red light or while parallel-parking. **Ship this gated behind its
own flag, off by default, after Phase 1 has a drive-test under its belt** — auto-escalation taking
over someone's screen while driving is exactly the kind of behavior that needs real-road validation
before being trusted, and bundling it into the same build as the default-screen flip makes any bug
report ambiguous about which change caused it.

### 0.6 — Flag/phasing + migration risk

**Recommendation: two flags, two builds, following the `communityEnabled`/`regularsEnabled`
playbook exactly** (dark-ship `false`, named guard tests, flip only after a drive-test gate records
clean in `HANDOFF.md` — the same gate discipline used for build 20→22's community flip,
`HANDOFF.md` 2026-09-14 entry, PR #109, "4 dark-ship guard tests transformed into launched-world
assertions").

- `AppConstants.driveModeDefaultEnabled` — Phase 1: ambient home screen default **+ the goal-first
  selector (§0.8) as its centerpiece** + manual-tap escalation (now via the demoted secondary
  affordance, §0.8.7) + persistent Search icon + permission priming + the `enterCruiseMode()`
  auth-request fix (§0.2). **AMENDMENT, 2026-10-20 — goal-first rides this SAME flag, not a second
  one.** Recommendation and rationale: an ambient home screen whose only centerpiece is a generic
  "Find a Spot" pill is, in Kevin's own 2026-10-20 framing, "pointless" on its own — the whole point
  of flipping the default screen is to put the goal-first answer in front of the user immediately.
  Shipping them as two separate flags would let someone flip the ambient-default half live without
  its actual payload, which serves no real intermediate state worth dark-shipping alone. Dark-ships
  `false`; guard tests assert `activeSheet` still defaults to `.browseNav`,
  `dismissTargetOutsideBrowseNav` still resolves to `.browseNav`, **and no goal selector, no
  full-palette toggle, and no goal-filtered overlay render anywhere** when the flag is off — zero
  behavior change for existing users until flipped. (If Kevin wants the two halves decoupled for
  risk-reduction reasons — e.g. ship the bare ambient screen first, flip goal-first later — that is
  a one-line override of this recommendation; flag it in §0.8 open decisions if so.)
- `AppConstants.cruiseAutoEngageEnabled` — Phase 2 (§0.5): motion-aware auto-escalation. Separate
  flag, separate build, flipped only after Phase 1 has shipped clean AND its own drive-test
  (auto-escalate/de-escalate thresholds genuinely need real-road tuning, not a simulator run).

**Why two builds, not one:** this spec touches `ContentView.swift` (the file with the single most
reliable regression history in this project — the #31 revert, three separate re-landing PRs, and
the FT-20 Stream A/B/C sequencing all trace back to exactly this file) and reworks a presentation
assumption (§0.4's sheet-reachability rewiring) that's been stable since FT-20 shipped. Landing the
default-screen flip and a genuinely novel motion-detection service in the same build repeats the
"build 13 became unshippable from landing too much at once" lesson
(`HANDOFF.md` 2026-08-19 checkpoint) this project has already learned once.

### 0.7 — What this supersedes / reconciles

- **FT-20 browse-sheet work:** not retired — demoted (§0.4). Every Stream A/B/C artifact
  (`BrowseSheetDetentMath`, `BrowseSearchAreaView`, the detent-measurement machinery) is reused.
- **`docs/longpress-universal-plant-spec.md` (spec-first, Stream 2 not yet started):** composes
  cleanly, provided the implementing engineer does not collapse "ambient home screen" and
  `driveModeActive` into one boolean (the biggest-risk paragraph above). That plant spec's entire
  design — long-press is a no-op only while `driveModeActive` or block-select — continues to hold
  exactly as written, because this spec keeps `driveModeActive == false` at rest. **Sequencing
  recommendation: land this spec's Phase 1 before long-press-plant Stream 2 starts**, so that
  spec's engineer builds against the final `driveModeActive`/rest-state semantics (including the
  `dismissTargetOutsideBrowseNav` change in §0.4) rather than against ones about to shift under
  them. No content change needed to that spec itself.
- **`docs/patrol-mode-feasibility-spec.md` ("Smart Sweep," feasibility-only):** reinforces, doesn't
  change, that spec's own §7.1 recommendation — "Smart Sweep is Cruise Mode gaining a second
  voice/card line, not a new top-level mode." Once Cruise is the default home screen rather than a
  secondary button, there is even less reason for a parking-route feature to live anywhere else.
  No action required on that spec now; cite this spec when Smart Sweep is eventually built.
- **Open item #18 (overnight "sea of green" nudge, not started) — SUPERSEDED 2026-10-20, not just
  re-targeted.** The original note below (kept for history) proposed a dismissible evening nudge
  pointing at the existing clock-icon Park Until sheet. **§0.8's goal-first selector subsumes this
  outright** — there is no separate nudge to build; the ambient home screen's own centerpiece *is*
  the overnight answer, present at every launch, not just in the evening. Close #18 against §0.8,
  not against a standalone nudge build.
  <br>*Original note, preserved:* currently speced as an "evening browse nudge" fired from inside
  the browse sheet (`docs/open-items.md` row 18). With the sheet demoted to pull-up (§0.4), a nudge
  that depends on the sheet being visibly open in the evening won't reliably surface.
- **Open item #35 (goal-first parking, Kevin 2026-10-20) — IMPLEMENTED by §0.8.** The item that
  triggered this entire amendment. Close #35 against §0.8 once Phase 1 ships.

---

## §0.8 — GOAL-FIRST AMENDMENT (Kevin, 2026-10-20 — locked, supersedes §0.1's generic pill)

### 0.8.1 — The three goals and what each resolves to

| Goal | Icon/copy | What it answers | Bar |
|---|---|---|---|
| **Free overnight** (DEFAULT, pre-selected) | 🌙 "Free overnight" | "Will I have to move it for tomorrow's sweep?" | Low — clears tonight + all of tomorrow |
| **Free a few hours** | ⏱ "Free a few hours" | "Can I leave it untouched — no payment, no risk — for a few hours?" | Low — a short, strict window |
| **Park & forget** | 🅿️ "Park & forget" | "What's the longest I can leave it without moving it at all?" | High — the holy grail, needs graceful degradation (§0.8.9) |

All three resolve to a target `Date` (or, for Park & Forget, a ladder of candidate dates — §0.8.3)
fed into the **exact same** `parkUntilMode = true` / `parkUntilTarget` state Park Until already
uses (`ContentView.swift:559-563`), which already drives the binary green/red `rebuildOverlays()`
branch (`:1921-1973`). **No new map-rendering code.** What's new is (a) how each goal's target is
computed, (b) a new engine parameter two of the three goals need, and (c) the big-button selector UI
that replaces the small clock icon as the PRIMARY entry point.

### 0.8.2 — Free overnight: the ASP side-swap is the real job, not a clock hour

**Kevin's correction (2026-10-20, locked):** pure "can I park overnight" is not the hard question —
you can, almost everywhere. The hard question is **"will I have to move the car for tomorrow
morning's street-cleaning sweep?"** A naive window like "now → tomorrow 8am" is wrong for two
reasons: (1) ASP start times vary by zone (8am/8:30/9/9:30/11:30, etc. — a fixed clock cutoff would
either falsely clear a block whose sweep starts later than the cutoff, or falsely flag a block
with no sweep at all tomorrow afternoon); (2) it answers "is this legal right now through a clock
time," not "do I have to touch the car tomorrow."

**Resolution: target = midnight at the start of the day AFTER tomorrow — a calendar-day boundary,
not a clock hour.** Concretely: `Date.nowET.startOfDayET(offsetDays: 2)` (the exact helper
`ParkUntilSheet.tonightMidnight()` already uses with `offsetDays: 1` — this is the identical idiom,
one day further out). Running `isFree(segment:from: .nowET, until: thatMidnight)` evaluates the
**entire calendar day of "tomorrow,"** midnight to midnight, regardless of what hour tomorrow's
ASP/no-standing/no-parking rule actually starts — a day-boundary target makes the per-zone start
time irrelevant, because the window fully contains it either way. A segment matches ("you won't
have to move it") iff nothing move-forcing fires anywhere in [now, day-after-tomorrow's midnight).
**This needs zero new date-math beyond reusing the existing day-offset helper with a bigger number
— the insight is using a day boundary instead of a guessed clock hour, not new engine code.**

**But metered payment must NOT disqualify a match (§0.8.4).** Today's `isFree()` treats a metered
rule's billing hours as a blocking restriction (`:749-762`, by design — correct for Park Until's
"is this curb unrestricted AND unpaid" promise). Free Overnight's promise is narrower and
different: **"will I have to MOVE it,"** and paying a meter does not require relocation. A block
with free overnight + metered 8am-7pm tomorrow should still read "you won't have to move it" even
though you'd owe money if you came back at noon — that's an honest, different question, and
goal-first's copy must never imply "free of charge," only "free of needing to move." See §0.8.4 for
the engine change this requires.

### 0.8.3 — Park & forget: the same question, taken to its ceiling

**Park & forget is Free Overnight's own predicate, asked repeatedly with a widening window
instead of one fixed 2-day checkpoint.** Reconciling the two goals (Kevin's ask #4): Free Overnight
clears ONE low hurdle (survive tomorrow); Park & Forget is the search for how many hurdles in a row
a given block clears. Ladder, evaluated per-segment using the SAME move-relevant predicate as
Free Overnight (§0.8.4):

1. Try `until = .nowET.startOfDayET(offsetDays: 8)` (7 full days out — matches `ParkUntilSheet`'s
   own existing `maxDate` cap, `:87`, "the engine itself has no upper bound but DatePickers feel
   awkward past a week" — same reasoning applies to a goal-resolved window).
2. If a segment fails at 7 days, step down and retry at `offsetDays: 4`, then `offsetDays: 2`
   (identical to Free Overnight's own checkpoint — a block that fails Park & Forget's bottom rung
   degrades gracefully into "well, at least it clears Free Overnight," see §0.8.9's empty-map
   guard, not a dead end).
3. The segment's matching bucket (green/red) is determined by which rung it clears, and the SAME
   rung's date powers the ranking label (§0.8.3a) — one predicate call per rung tried, no separate
   ranking pass needed.

**0.8.3a — Ranking/labeling, both goals:** among a goal's matching (green) segments, Kevin wants
the genuinely-better ones distinguishable ("a Mon/Thu side found Monday night beats a Wed/Sat side
found the same night"), with an honest value line like **"Good through Thursday."** This reuses the
exact ladder-walk above (or, for Free Overnight specifically, one extra widening check beyond its
single checkpoint) to find the actual next move-forcing date per matching segment, formatted via
the already-shipped `ParkUntilSheet.formatTime`-style relative-day formatter (`:217-248`,
"Tomorrow"/"Mon"/"MMM d" tiers — reuse verbatim for a date-only variant). **This does not touch the
5-color palette or the binary overlay bucket** — ranking is a label/sort concern on top of the
already-decided green bucket, never a new color.

**ASP-suspension honesty (Kevin's ask #3):** `isFree()`'s existing suspension-skip (`:704`) already
makes a suspended tomorrow a non-event — the day-walk simply continues past it to the next real
restriction. **No new code needed for this edge case** — it falls out of reusing the existing
suspension-aware day-walk unchanged; the ranking label will naturally read further out (e.g. "Good
through Thursday" instead of "Good through Tuesday") on a block whose Tuesday ASP day happens to be
suspended, which is the correct, honest answer without any special-cased sentence.

### 0.8.4 — The one real new piece of engine surface: `ignoringMeteredPayment`

**New, small, additive parameter on the already-tested `isFree()`:**

```
func isFree(segment: Segment, from: Date = .nowET, until: Date,
            ignoringMeteredPayment: Bool = false) -> Bool
```

Default `false` preserves every existing call site byte-for-byte (Park Until's own clock-icon flow
is UNTOUCHED — this is additive, not a behavior change to a shipped feature). When `true`, the
`cat == .metered` branch (`:749-762`) is skipped entirely in the day-walk — metered billing hours
no longer disqualify a match — while every other branch (ASP incl. suspension-skip, no standing,
no parking, truck loading, time-range overlap logic) is untouched. **Free overnight and Park &
forget both call `isFree(..., ignoringMeteredPayment: true)`** (their job is "would I have to move
it," and paying a meter isn't moving). **Free a few hours calls `isFree(..., ignoringMeteredPayment:
false)`** — unchanged strict semantics (§0.8.5) — because a short errand-parking promise of "zero
required action for N hours" is reasonably broken by an active meter requiring payment.
**New unit tests required:** a segment with an active metered rule inside the window must return
`false` when the flag is omitted/false (regression guard — the existing 659-line function's
behavior must not silently change for its one already-shipped caller) and `true` when the flag is
`true` and no non-metered rule conflicts. **Sizing note (§4): this is the one piece of this
amendment that is genuinely new engine code, not pure reuse — small and isolated, but real,
reviewable, testable surface, not a client-side relabeling exercise.**

### 0.8.5 — Free a few hours: the simple case, unchanged semantics

Resolves to `until = .nowET.addingTimeInterval(3 * 3600)` (+3h — splits the difference between
`ParkUntilSheet`'s existing 2hr/4hr presets; a small, trivial addition to that preset family's
pattern, not a new mechanism). Calls `isFree(..., ignoringMeteredPayment: false)` — today's strict,
already-shipped, already-tested semantics apply unchanged. No new engine surface for this goal.

### 0.8.6 — The map answer: reusing Park Until's binary overlay verbatim

Picking any goal sets `parkUntilMode = true` and `parkUntilTarget` to the goal's resolved date (or,
for Park & Forget, the date of the highest rung the overall viewport's segments collectively
clear — see §0.8.9 for the exact per-segment-vs-global nuance) and calls the existing
`rebuildOverlays()` — **byte-identical to today's Park Until code path** (`:1921-1973`): matching
segments bucket into `freeComfortably` (green), non-matching into `restrictedNow` (red), the other
three of the five palette buckets (`freeButRestrictionSoon`, `meteredActive`, `unknown`) are empty.
**The 5-color palette is not touched, extended, or violated** — goal-first is a filter DOWN to 2 of
the existing 5 colors, exactly as Park Until already ships, never a new color or a dimmed/third
visual state. "Matching spots prominent" is achieved for free by this binary reduction itself —
green is the only color on screen that means "yes," there's nothing competing with it for
attention. Selected-block highlighting (`:1948-1959`) is unchanged.

### 0.8.7 — Two postures reconciled: the selector is ambient-only; the filter rides into Drive

The goal selector itself (three big buttons) lives **only on the ambient home screen** — it is not
rebuilt inside the escalated Cruise session. This matches `ParkUntilPill`'s existing documented
behavior exactly (`ContentView.swift:2653-2655`: "carried over from browsing if already active;
cannot be entered mid-drive... hidden while `driveModeActive == true`"). Concretely: tapping a goal
button sets `parkUntilMode`/`parkUntilTarget` and rebuilds overlays **without** escalating — the
user stays in the ambient/resting posture (§3.1's two-posture model, untouched by this amendment),
now looking at a goal-filtered map instead of the full 5-color one. **The old "Find a Spot" pill's
job — triggering `enterCruiseMode()` — survives as a secondary, smaller affordance below the goal
selector** (copy TBD by @designer, e.g. "Start driving" / "Go") so Kevin's ideal flow — *"goal set,
then heading-up with only matching spots lit"* — works exactly as he described: pick a goal (map
answers it, zero escalation), then tap the secondary affordance to escalate into Cruise, which
inherits the already-set `parkUntilMode`/`parkUntilTarget` for free (identical mechanism to how
today's clock-icon Park Until already survives the ambient→Cruise transition, unchanged by this
spec). **Still only one escalation trigger in Phase 1** — §0.5's auto-escalation remains its own
later phase, untouched.

### 0.8.8 — Full palette as a switchable mode, not the default

**Goal-first leads; full-palette is one deliberate tap away, not deleted.** A small, clearly-labeled
toggle/switch near the goal selector (exact placement/style: @designer, but same `.regularMaterial`
44×44pt-or-larger family as `recenterButtonStack`, bigger-touch-target convention) flips OUT of
goal-first: tapping it is **functionally identical to today's already-shipped
`clearParkUntilFilter()`** (`:4700-4705`) — sets `parkUntilMode = false`, clears `parkUntilTarget`,
rebuilds overlays into the standard 5-color `currentState()` classification (`:1975-1995`,
untouched). Tapping back into any goal re-applies it via the same set-state-and-rebuild path.
**Zero new engine logic for the toggle itself** — it's a prominent, intentional front door onto an
existing function, the same way the goal buttons are a prominent front door onto `isFree()`.
Copy: something honest like "Show all parking rules" or "Switch to full map" — never implies the
goal-filtered view is hiding something dishonestly; it's a different, equally-valid lens.
**Persistence across launches (remember the last mode/goal) is explicitly NOT required for Phase
1** — every cold launch defaults to goal-first + Free Overnight pre-selected (§0.8.1), full stop;
see §6 follow-ups for the "remember my last choice" deferral.

### 0.8.9 — Custom/power-user path reconciled: the clock stays, demoted

Kevin chose exactly three preset goal buttons, deliberately with **no custom-time picker as a
primary button.** The existing `ParkUntilSheet` (presets + custom `DatePicker`, Confirm/Skip) is
**not deleted and not changed** — it remains the power-user path, reachable from the full-palette
mode's own clock-icon affordance (today's `recenterButtonStack` button 3, `:2745-2757`) once a
user has toggled OUT of goal-first (§0.8.8). It is **not** surfaced as a fourth goal button and
is **not** reachable directly from the goal-first home screen — this is a deliberate simplicity
choice (Kevin's ruling), not an oversight. A user who wants "free until I personally leave, at some
specific time I choose" switches to full-palette mode first, then taps the clock icon exactly as
they do today. No new UI needed for this path — it already exists, unchanged.

### 0.8.10 — The biggest NEW risk: an empty-looking map, and how it degrades gracefully

**Park & Forget is the one goal that can plausibly return near-zero matches in a dense
alt-side-parking neighborhood** — nearly every Manhattan blockface carries SOME weekly ASP day, so
"clear for a full 7 days" is a genuinely rare bar, by design (it's the holy grail). A goal screen
that resolves to "everything within view is red" reads as **broken**, not "honestly rare" — this is
the single biggest new risk this amendment introduces, bigger than Free Overnight's or Few Hours'
risk (both have a much lower bar and will realistically paint plenty of green in ordinary use).

**Mitigation — the step-down ladder (§0.8.3) is not optional polish, it's the guardrail:** Park &
Forget's ladder (offsetDays 8 → 4 → 2; 7 → 3 → 1 full clear days) means the map never needs to show "zero matches" unless a block
fails even the 2-day Free-Overnight-equivalent checkpoint, which should be rare. When the ladder
has to step down for most/all visible segments, the UI must say so honestly — e.g. a small inline
banner: **"Nothing clear for a full week nearby — showing the best available."** The per-segment
ranking label (§0.8.3a, "Good through Thursday") already communicates the real result per block;
the banner is the map-level honesty check for when the ceiling goal degrades. **If even the lowest
rung (2 days / Free Overnight's own bar) returns zero matches in the visible viewport** — the true
worst case — show an explicit, non-broken-looking empty state (not a silent all-red map): "No
clear spots found very nearby — try Free Overnight, or pan the map." This must be built, not
discovered in QA; name it explicitly as an acceptance criterion (§5).

---

## §1 — Problem and user story

**Kevin's framing (verbatim, 2026-10-19):** "make drive mode the default and more intuitive — it's
by far the best and easiest use case, should arguably be the opening page." Followed by the
destination-less-Cruise choice described in the header above.

**The moment this solves:** today, opening WePark lands on a search-first sheet
(`BrowseNavigationSheet`, default `activeSheet = .browseNav`) whose primary button happens to be
"Find a Spot" — but the sheet's own layout puts a search field above it, and the sheet itself
partially occludes the map (the actual product, per Kevin's own earlier ruling against system
`.medium` — `BrowseNavigationSheet.swift:65-70`). The single most common, easiest use case — "I'm
already somewhere in Manhattan, show me what's free right now" — currently requires parsing a
search-first UI to find the one button that doesn't need a destination. Kevin's ruling collapses
that: the map, your location, and live curb colors should just be *there* the instant the app opens,
with zero required input.

**User story:**
> As someone opening WePark, I want to immediately see live parking conditions around me with no
> destination, no search field, and no required taps — and when I'm ready to actually drive and
> look for a spot, one tap (or, eventually, just driving) should take me into the full voice-guided
> Cruise experience I already have today.

**Why now:** Cruise Mode (`docs/cruise-mode-spec.md`) and its entire camera/voice/overlay stack are
already shipped and stable. This spec is subtractive-and-rearranging at its core for Phase 1 — it
does not build a new drive experience, it changes which screen a user lands on and how they reach
the one that already exists.

**AMENDMENT — 2026-10-20, Kevin's second framing (verbatim):** *"the green/red curb palette answers
'legal right now,' but the real NYC job is intent — a spot free tonight AND tomorrow, don't move
it."* **Updated user story:**
> As someone opening WePark, I want to be asked what I actually need — not handed a wall of colors
> to decode — and the map should collapse to answer that one question. If I'm parking for the
> night, tell me whether I'll have to move the car tomorrow morning, not just whether it's legal
> right now. If I want the full picture, that's one tap away, not gone.

This does not replace the §1 "why now" above — Cruise Mode's shipped stack is still exactly why
Phase 1 is reachable now — it sharpens WHAT the ambient home screen's one primary affordance
actually is (§0.8), because a generic "Find a Spot" pill, on its own, doesn't deliver the value
Kevin is actually describing here.

---

## §2 — Scope

### 2.1 In scope (Phase 1 — `driveModeDefaultEnabled`)

1. Flip the home screen's rest state from a default-open `.browseNav` sheet to no sheet
   (`activeSheet == nil`), with the **goal-first selector (§0.8) — not a generic "Find a Spot" pill
   — as the always-visible, centerpiece primary affordance at rest** (AMENDED 2026-10-20; the
   demoted secondary "start driving" affordance from the original pill, §0.8.7, is also always
   visible but visually subordinate).
2. Rework `dismissTargetOutsideBrowseNav` so every sheet dismissal returns to the new rest state,
   not back into `.browseNav` (§0.4).
3. A persistent Search icon affordance that presents `.browseNav` at `.medium` on tap (§0.4a's Job B
   mitigation).
4. Rework `BrowseNavigationSheet`'s presentation configuration from "permanent, non-dismissible
   peek/medium companion" to "normal, dismissible, on-demand sheet" (§0.4's last bullet).
5. One-shot, dismissible first-launch location-priming card (§0.2), following the
   `BackgroundNoteGate` pattern.
6. The `enterCruiseMode()` authorization-request fix (§0.2) — required, not optional.
7. Denied/restricted graceful-degradation copy + Settings deep link on the ambient pill.
8. Flag scaffold (`AppConstants.driveModeDefaultEnabled`) + named guard tests proving zero behavior
   change while `false`.
9. Mandatory live-UI smoke (screenshot-verified, both flag states) per this project's standing #31
   norm, given the files touched.
10. **(AMENDED, 2026-10-20) The goal-first selector UI**: three large buttons (bigger-touch-target
    convention — these are the biggest buttons in the app, per standing feedback), Free Overnight
    pre-selected/default on every cold launch (§0.8.1).
11. **New `isFree(..., ignoringMeteredPayment: Bool = false)` parameter** on
    `ParkingRulesEngine.isFree()` (§0.8.4) + new unit tests for both the `false` (regression guard,
    unchanged) and `true` (new) branches.
12. **Goal-resolution functions** for all three goals (§0.8.2, §0.8.3, §0.8.5), including Park &
    Forget's step-down ladder and the per-segment "Good through <day>" ranking label (§0.8.3a).
13. **The empty-map guard** (§0.8.9/§0.8.10): the "showing the best available" banner and the
    explicit non-broken-looking empty state when even the lowest rung returns zero nearby matches.
14. **The full-palette toggle** (§0.8.8) — a prominent switch, functionally wired to the existing
    `clearParkUntilFilter()` path.
15. **Reconciling the demoted escalation trigger and the Search icon with the goal selector's new
    layout** — the ambient screen now has three primary buttons, one secondary "start driving"
    affordance, one full-palette toggle, and the persistent Search icon (§0.4) all coexisting;
    this is real layout work, not a drop-in replacement of one pill with three.
16. Live-UI smoke (screenshot-verified) specifically for: Overnight pre-selected at cold launch,
    switching goals, the full-palette toggle, and the empty-map guard — added to item 9's mandatory
    smoke set, not a separate gate.

### 2.2 In scope (Phase 2 — `cruiseAutoEngageEnabled`, separate build, gated on Phase 1 drive-test)

1. New motion-detection service (pure-function, hysteresis-gated, unit-tested) answering "has
   sustained driving-speed motion started/stopped."
2. Auto-promotion to `driveModeActive = true`/`.cruise` on sustained motion; auto-demotion to
   ambient on sustained stillness.
3. Its own real-drive tuning cycle for the speed/duration thresholds.

### 2.3 Out of scope (explicitly deferred, this spec)

- Any change to `CruiseVoicePolicy`, `FinalApproachService`, the 5-color palette, the camera
  pitch/zoom/style constants, or any destination-mode Drive Mode behavior — all reused byte-for-byte.
- Any change to `longpress-universal-plant-spec.md`'s own design — composes as-is (§0.7).
- "Smart Sweep" / patrol-mode directive guidance — unrelated, separate future spec (§0.7).
- ~~Open item #18's actual build — only its attachment point is re-targeted here~~ **SUPERSEDED,
  2026-10-20: #18 (and #35) are now fully IN scope, implemented by §0.8 — not merely re-targeted.**
- **Deferred by this amendment:** a fourth "custom goal" button, remembering the user's last-chosen
  goal/mode across launches, and a density-aware smarter default goal (e.g. auto-suggesting Park &
  Forget when the viewport has lots of multi-day-clear blocks) — see §6.
- Android — not applicable; iOS-only project.
- Removing or renaming `enterCruiseMode()`, `DriveModeStyle`, `.cruise`, or any other internal
  identifier — Phase 1 reuses all of them unchanged, consistent with FT-20's own §0f precedent of
  changing labels without refactoring internals.

---

## §3 — Architecture

### 3.1 The two-posture model (the load-bearing design decision)

This spec does **not** introduce a third `DriveModeStyle` case or a new top-level "home mode." The
existing two states already describe everything needed:

- **Ambient/resting** = `activeSheet == nil && driveModeActive == false`. Map, curb colors, default
  blue dot, ambient pill. No camera escalation, no voice, no wake lock, no continuous GPS.
- **Escalated/Cruise** = `driveModeActive == true && driveModeStyle == .cruise`. Exactly today's
  shipped Cruise session (`docs/cruise-mode-spec.md`), reached via `enterCruiseMode()`, unchanged.

Phase 1's entire job is changing *what the ambient/resting state looks like by default* and *how a
user reaches the escalated state* — not changing what the escalated state does. Phase 2 adds a third
way to reach escalated (motion detection) without changing either posture's definition.

### 3.2 Codebases touched

**iOS only.** PWA stays in maintenance mode, untouched. Backend is not touched — no new tables,
RPCs, or migrations. This is a client-side state/presentation rework plus one new small service
(Phase 2).

### 3.3 Files — Phase 1

| File | Change | Risk |
|---|---|---|
| `ios/WePark/WePark/ContentView.swift` | `activeSheet` default (`:483`), `dismissTargetOutsideBrowseNav` (`:1248-1251`), **replace** the ambient-pill view with the goal selector + demoted secondary affordance + full-palette toggle (new, AMENDED 2026-10-20, §0.8 — larger surface than the original pill), new persistent Search icon (new, small, same family as `recenterButtonStack`), `enterCruiseMode()` auth-request fix (`:3036-3045`), first-launch priming card wiring, flag reads, **new goal-selection state wiring onto the existing `parkUntilMode`/`parkUntilTarget` (`:559-563`) and `rebuildOverlays()` (`:1913-1995`) — no new overlay-rendering code, only new callers of it**, **the empty-map guard banner (§0.8.10).** | **High** — this is the file with the project's single worst regression history (#31 and its three-PR re-landing trilogy). AMENDMENT increases this file's surface area for Phase 1; mandatory live-UI smoke, both flag states, both pre/post dismiss-target flip, plus all three goals + full-palette toggle + empty-map guard. |
| `ios/WePark/WePark/Services/ParkingRulesEngine.swift` | **NEW for this amendment, 2026-10-20 — was previously untouched by this spec.** Add `ignoringMeteredPayment: Bool = false` parameter to `isFree(segment:from:until:)` (`:659`, §0.8.4) — skip the `cat == .metered` branch (`:749-762`) when `true`; every other branch untouched. | **Medium** — a well-tested, isolated pure function gets one additive, default-preserving parameter. New unit tests required for both branches (§0.8.4); existing Park Until tests must stay green unmodified (default `false` preserves current behavior byte-for-byte). |
| `ios/WePark/WePark/Views/BrowseNavigationSheet.swift` | Presentation-configuration rework: from permanent/non-dismissible to normal on-demand sheet. Content (search field, "Find a Spot" button, "New to parking?" link) unchanged. | Medium — real behavior change to how the sheet is hosted, even though its content doesn't change. |
| `ios/WePark/WePark/Views/ParkUntilSheet.swift` | **Reused verbatim, zero changes.** The power-user/custom path (§0.8.9) is reached from full-palette mode exactly as it is today — `ParkUntilSheet`, `ParkUntilPill`, and `ParkUntilSheet.formatTime` are all unmodified by this amendment; the goal-first front door is new, the sheet behind it is not. | None — included for completeness/reuse-tracking, not touched. |
| `ios/WePark/WePark/Services/LocationService.swift` | No internal change required — `requestAndFetchLocation()` is reused as-is. (The fix in §0.2 lives in `ContentView.swift`'s `enterCruiseMode()`, not here.) | None — included for completeness, not touched. |
| New: `ios/WePark/WePark/Views/GoalSelectorView.swift` (name TBD, AMENDED 2026-10-20) | The three large goal buttons + full-palette toggle (§0.8.1, §0.8.8). **RE-SCOPED 2026-10-20 (work-stream disjointness):** the goal-resolution helpers do NOT live here — they live in the new `Services/ParkingGoals.swift` below (DM-2e's file), so DM-2e and DM-2 never touch the same file; this view only consumes them. | Medium — new file, but isolated; no existing call sites to regress, only new ones added to `ContentView.swift`. |
| New: `ios/WePark/WePark/Services/ParkingGoals.swift` (ADDED 2026-10-20, DM-2e) | Pure-Foundation goal-resolution layer (no SwiftUI import, per AC-14's service-file rule): a goal enum, per-goal target resolution (§0.8.2/§0.8.5), Park & Forget's offsetDays 8→4→2 ladder walk, and the per-segment "Good through <day>" date computation + relative-day label formatting (§0.8.3/§0.8.3a). Calendar.easternTime only. | Medium — new pure logic, fully unit-testable without UI; the one file where the amendment's genuinely new behavior lives alongside the `isFree()` parameter. |
| New: `ios/WePark/WePark/Views/LocationPrimingCard.swift` (or similar) | One-shot card, `BackgroundNoteGate`-style persistence. | Low — new, additive, no existing call sites. |
| New: `ios/WePark/WePark/Services/Constants.swift` | Add `driveModeDefaultEnabled` flag constant. | Low — mechanical, follows `communityEnabled`/`regularsEnabled` precedent exactly. |

**Do NOT touch for Phase 1:** `MapViewRepresentable.swift` (the heading-up/zoom/puck/overlay stack
is reused unchanged — the ambient posture needs none of it; the escalated posture already has it).
`DrivingContextService.swift`, `CruiseVoicePolicy.swift`, `FinalApproachService.swift` — all
untouched. **AMENDED:** `ParkingRulesEngine.swift` moves OFF this list for this amendment only
(see new row above) — everything else on it is still correctly untouched.

### 3.4 Files — Phase 2 (separate build, listed for completeness, not for Phase 1 dispatch)

| File | Change |
|---|---|
| New: `ios/WePark/WePark/Services/DriveAutoEngageService.swift` | Pure-function, hysteresis-gated motion detector. Mirrors `FinalApproachService`'s exhaustive-switch, no-framework-dependency pattern. |
| `ios/WePark/WePark/ContentView.swift` | Wire the new service's output into the existing `driveModeActive` flip — reuses `enterCruiseMode()`/`endDriveMode()` verbatim, does not fork them. |
| `ios/WePark/WePark/Services/LocationService.swift` | Possibly needs a lighter-weight continuous-but-coarse location mode to detect motion onset without paying full navigation-grade GPS cost before escalation — needs design during Phase 2, not resolved here. |

---

## §4 — Work streams

### Phase 1

| Stream | Owner | Serializes after | Est. |
|---|---|---|---|
| **DM-1** — Flag scaffold + `activeSheet`/`dismissTargetOutsideBrowseNav` default flip + guard tests | @ios-engineer | Nothing | 0.5–1 session |
| **DM-2e** — **(NEW, AMENDMENT)** `ParkingRulesEngine.isFree(..., ignoringMeteredPayment:)` (§0.8.4) + goal-resolution functions for all three goals incl. Park & Forget's step-down ladder + ranking label (§0.8.1–§0.8.3a, §0.8.5) + their unit tests | @ios-engineer | Nothing — different files from DM-1, can start day one | 1–1.5 sessions |
| **DM-2** — **(AMENDED)** Goal selector UI (three large buttons, Overnight pre-selected) + full-palette toggle + the demoted secondary "start driving" affordance + persistent Search icon + `BrowseNavigationSheet` presentation rework + empty-map guard banner (§0.8.6–§0.8.10) | @ios-engineer | DM-1 (reads flag/rest-state) AND DM-2e (consumes its resolution functions — can stub against DM-2e's interface signatures while it lands, then wire for real) | 2–2.5 sessions — **up from the original spec's 1–1.5; this is the real size delta the amendment introduces, called out honestly rather than absorbed silently** |
| **DM-3** — First-launch priming card + `enterCruiseMode()` auth-request fix + denied-state copy/Settings link | @ios-engineer | Can run in parallel with DM-2/DM-2e (different code surfaces — card is new, auth fix is a small addition inside `enterCruiseMode()`) | 1 session |
| **DM-4** — Live-UI smoke (both flag states, **all three goals, full-palette toggle, empty-map guard, pre-selected-Overnight-at-cold-launch**) + QA pass | @qa-verifier | DM-1, DM-2, DM-2e, DM-3 merged | 1.5 sessions — up from 1, the goal-first surface needs its own dedicated pass, not an add-on to the original ambient-pill smoke |
| **@designer** — goal button copy/icons (🌙/⏱/🅿️ or alternatives), full-palette toggle copy, "Good through <day>" ranking-label style, empty-map-guard banner copy, Search icon placement, priming-card copy | @designer | Runs in parallel with DM-1/DM-2/DM-2e/DM-3, non-blocking | — |

**Phase 1 total, AMENDED: ~5.5–7 engineering sessions + 1.5 QA sessions, plus Kevin's own manual
smoke** (irreducible for camera/default-screen changes per this project's own established lesson —
`HANDOFF.md`'s W8.5c-polish-PR-3 entry: "for camera/animation changes, Kevin's manual smoke is
irreducible verification"). Call it **7–9 sessions wall-clock** — up from the original draft's
5–6. **Honest sizing note:** the increase is real, not padding — it's the cost of this amendment
turning the ambient home screen's centerpiece from "repaint an existing button" into "three
goal-resolution functions (one with a new engine parameter and a step-down ladder), a new UI
component, and an empty-state guard." This is still, deliberately, still Phase 1 — see the phasing
discussion below for why it should not be split into its own phase.

**Phasing recommendation (resolves Kevin's explicit question): goal-first ships WITH Phase 1, not
as its own phase.** An ambient-default home screen whose only payload is a relabeled "Find a Spot"
pill is not worth shipping on its own — per Kevin's own 2026-10-19→10-20 arc, the destination-less
home screen's entire reason to exist is to answer "what's free right now," and goal-first IS that
answer, sharpened. Splitting them into two phases would mean shipping a flag-flip that changes
where users land without changing what they get there — a confusing intermediate state with no
real user value, purely to make one build "smaller." The two-flag precedent elsewhere in this spec
(§0.5's Phase 2 motion-detection) exists because THAT phase is a genuinely separable, independently
risky capability (new sensor-driven state machine, needs its own real-road tuning cycle) — goal-
first has no such independent risk profile; it's UI + a small, well-tested engine parameter, fully
verifiable in simulator + Kevin's existing manual-smoke cadence. **Recommendation: one Phase 1,
sized honestly at 7–9 sessions above, not two phases.**

### Phase 2 (separate build, after Phase 1's drive-test gate)

| Stream | Owner | Est. |
|---|---|---|
| **DM-5** — `DriveAutoEngageService` (pure-function, tested) | @ios-engineer | 1–1.5 sessions |
| **DM-6** — Wiring into `ContentView` + flag scaffold | @ios-engineer | 0.5 session |
| **DM-7** — Real-drive tuning cycle (speed/duration thresholds) | Kevin (drives) + @ios-engineer (retunes) | At least 1 full cycle, calendar-slow, not session-slow |
| QA + Kevin's smoke | @qa-verifier + Kevin | 0.5–1 session + the drive itself |

**Phase 2 total: ~2–3 engineering sessions + at least one real-drive tuning cycle whose calendar
length depends on Kevin's availability, not engineering throughput** — the same honest caveat
`docs/patrol-mode-feasibility-spec.md` §6 applies to its own iteration tail, because "does this feel
right while actually driving" has no simulator-verifiable ground truth.

**No `@backend-data` work in either phase.** **No `@pwa-maintainer` work** — PWA stays in
maintenance mode, untouched.

---

## §5 — Acceptance criteria

**Flag off (`driveModeDefaultEnabled == false`) — zero behavior change:**
- [ ] **AC-1:** `activeSheet` still defaults to `.browseNav` on cold launch. `dismissTargetOutsideBrowseNav`
  still resolves to `.browseNav`. Byte-identical to pre-this-spec behavior.
- [ ] **AC-2:** No ambient pill, no persistent Search icon, no priming card render anywhere.

**Flag on — ambient home screen:**
- [ ] **AC-3:** Cold launch shows no sheet. The map, curb-color overlays, default blue dot (not the
  drive chevron), ASP banner (if applicable), Report pill (if `communityEnabled`), My Car marker (if
  parked), and the ambient "Find a Spot" pill are all visible with zero required taps.
- [ ] **AC-4:** Tapping the ambient pill calls `enterCruiseMode()` and produces the exact same
  escalated session as today's shipped Cruise Mode — heading-up camera, auto-zoom, `.mutedStandard`
  style, directional puck, voice gated by `CruiseVoicePolicy`. No visual or behavioral difference
  from pre-this-spec Cruise Mode.
- [ ] **AC-5:** Long-press-to-plant (today's flag-on/flag-off behavior, whichever is currently
  shipped) works identically at rest on the new home screen — no regression from the default-state
  change.
- [ ] **AC-6:** Dismissing any non-`.browseNav` sheet (block detail, pin detail, parked-car detail,
  etc.) returns to the ambient home screen (no sheet), not back into `.browseNav`.
- [ ] **AC-7:** Tapping the persistent Search icon presents `.browseNav` at `.medium` detent.
  Dismissing it returns to the ambient home screen.
- [ ] **AC-8:** `.browseNav`'s content (search field, "Find a Spot" button, "New to parking?" link,
  trailing-edge Settings gear) is pixel-identical to pre-this-spec FT-20 content.

**Permissions and degradation:**
- [ ] **AC-9:** On a fresh install (`.notDetermined`), cold launch shows `manhattanCenter` (or last
  cached fix if present), fires no system permission prompt automatically, and shows the one-shot
  priming card exactly once ever (verify via a forced-reinstall or `UserDefaults` reset — it must
  not reappear on a second launch after being dismissed).
- [ ] **AC-10:** Tapping "Allow" on the priming card fires the real system location prompt.
  "Not now" dismisses with zero side effects.
- [ ] **AC-11:** With location `.notDetermined` or `.denied`, tapping the ambient pill either (a)
  routes through `requestAndFetchLocation()` first if `.notDetermined` (the required fix, §0.2), or
  (b) shows the denied-state copy + Settings deep link if `.denied`/`.restricted` — never silently
  does nothing.
- [ ] **AC-12:** With location denied, search, long-press-to-plant, and the Report pill all continue
  to work fully — curb-color coverage renders anywhere the user pans/zooms, independent of location
  permission.
- [ ] **AC-13:** At rest (ambient posture), `LocationService` never enters its continuous
  navigation-grade posture (`startDriveMode()`'s accuracy/activityType/wake-lock/distanceFilter
  settings, `LocationService.swift:188-201`) — verify by code inspection AND by confirming
  `UIApplication.shared.isIdleTimerDisabled` stays `false` until the ambient pill is tapped.

**Tests:**
- [ ] **AC-14:** `xcodebuild test` exits 0. No `Calendar.current`. No `import SwiftUI` in service
  files. New guard tests for the flag-off byte-identical claims (AC-1/AC-2) are named explicitly in
  the PR, not left implicit.

**Live-UI smoke (mandatory pre-merge gate, both flag states):**
- [ ] **AC-15:** Screenshot, flag off: full existing toolbar/sheet chain renders exactly as today.
- [ ] **AC-16:** Screenshot, flag on, ambient state: map + curb colors + ambient pill + (ASP banner /
  Report pill / My Car marker as applicable) all visible, no sheet.
- [ ] **AC-17:** Screenshot, flag on, after tapping the ambient pill: escalated Cruise session
  renders identically to today's shipped Cruise Mode screenshots.
- [ ] **AC-18:** Kevin's manual smoke confirms: (a) cold launch feels immediate, not search-first;
  (b) the ambient pill tap-to-escalate transition is smooth, no frame shows a half-transitioned
  state; (c) dismissing any sheet lands back on the ambient screen, not `.browseNav`; (d) long-press
  planting still works at rest; (e) no permission prompt fires without the priming card or an
  explicit tap.

**Phase 2 (separate PR/build, not blocking Phase 1):**
- [ ] **AC-19:** Sustained motion above the tuned threshold for the tuned duration auto-promotes to
  escalated Cruise. Sustained stillness for the tuned duration auto-demotes back to ambient. Neither
  flaps at a red light or a parking maneuver (verified on a real drive, not just a unit test).
- [ ] **AC-20:** Flag off, zero behavior change from Phase 1's shipped state.

**Goal-first (AMENDMENT, 2026-10-20 — Phase 1, same `driveModeDefaultEnabled` flag):**
- [ ] **AC-21:** Flag on, cold launch: the goal selector (three large buttons) is visible with
  **Free Overnight pre-selected**, and the map is ALREADY showing Free Overnight's binary
  green/red filtered answer — zero taps required (§0.8.1, §0.4a).
- [ ] **AC-22:** Tapping "Free a few hours" or "Park & forget" immediately re-filters the map
  (binary green/red, via the existing `rebuildOverlays()` path) without opening any sheet or
  dialog — a single tap, no confirm step.
- [ ] **AC-23:** `isFree(segment:from:until:ignoringMeteredPayment:)` — default `false` produces
  byte-identical results to pre-amendment `isFree()` on every existing Park Until test case
  (regression guard). `true` additionally treats a metered-active rule inside the window as
  non-blocking while every other category (ASP incl. suspension, no standing, no parking, truck
  loading) still disqualifies exactly as before (§0.8.4).
- [ ] **AC-24:** Free Overnight's target resolves to `.nowET.startOfDayET(offsetDays: 2)` — a
  segment with an ASP day tomorrow (any start hour) is classified non-matching (red); a segment
  with its next ASP day the day after tomorrow or later is classified matching (green) (§0.8.2).
- [ ] **AC-25:** Park & Forget's step-down ladder (offsetDays 8 → 4 → 2, i.e. 7 → 3 → 1 full
  clear days — rungs locked by Kevin's 2026-10-20 ruling + tile-data analysis, see the rulings
  block in the amendment banner) is verified per-segment: a block that clears the top rung is
  labeled/ranked above one that only clears the bottom (§0.8.3a) — tested with at least one real
  or synthetic case at each rung.
- [ ] **AC-26:** A suspended ASP day inside a goal's window is correctly treated as a non-event —
  the segment's matching status and ranking label both reflect the suspension (i.e., resolve to
  the next REAL restriction date, not the suspended one) (§0.8.3a).
- [ ] **AC-27:** The full-palette toggle reverts the map to the standard 5-color
  `currentState()` classification, functionally identical to today's `clearParkUntilFilter()`
  output; toggling back into any goal re-applies it (§0.8.8).
- [ ] **AC-28:** The power-user custom-time path (`ParkUntilSheet`, presets + `DatePicker`) is
  reachable, unmodified, from full-palette mode's clock icon — byte-identical to pre-amendment
  behavior; it does NOT appear as a fourth button on the goal-first screen (§0.8.9).
- [ ] **AC-29:** Empty-map guard — a synthetic/forced scenario where Park & Forget's ladder cannot
  clear even its lowest rung for any visible segment shows the explicit non-broken-looking empty
  state copy, never a silent all-red map (§0.8.10).
- [ ] **AC-30:** Picking a goal does NOT escalate into Cruise — `driveModeActive` stays `false`;
  the demoted secondary "start driving" affordance is the only escalation trigger, and the
  already-set `parkUntilMode`/`parkUntilTarget` survives into the escalated session unchanged
  (§0.8.7, mirrors today's shipped Park Until carry-over behavior).
- [ ] **AC-31 (live-UI smoke):** Screenshots covering: cold launch with Overnight pre-selected and
  the map already filtered; tapping each of the other two goals; the full-palette toggle both
  directions; the empty-map guard state; and Kevin's manual confirmation that the copy never uses
  "avoid/ticket/fine/evasion/dodge" anywhere in the goal buttons, ranking labels, or guard banner.
- [ ] **AC-32 (ADDED 2026-10-20, Kevin: "the chevron sign and heads-up facing is crucial to the
  experience"):** Kevin's Phase-1 drive smoke explicitly verifies the escalated session's chevron
  puck + heading-up camera feel spot-on **when entered via the new ambient screen's demoted
  escalation affordance** — the new entry path must produce zero regression vs today's Cruise
  entry. **TF2-16** (heading behavior at intersection approaches — still never deliberately
  watched on any drive) is folded into this same gate as a named watch item. Related but
  separate: open item **#36** (heading-EMA convergence tune + the designer's puck/compass audit,
  `docs/design/drive-puck-chevron-review.md`) — if its fix rides the same build, this gate also
  judges it.

---

## §6 — Out-of-scope follow-ups (noticed, explicitly punted, with rationale)

- ~~Renaming "Find a Spot" to "Parking Near Me."~~ **MOOT as of 2026-10-20** — the generic pill
  this bullet was about no longer exists; the goal selector's own copy is §0.8's concern now
  (@designer, §4).
- **Removing the FT-20 sheet's "New to parking?" link from the pulled-up sheet, or promoting it to
  the ambient screen.** Not requested, not implied by Kevin's framing. **Note (2026-10-20): the
  ambient screen is no longer "one pill, no secondary links"** — it now carries three goal buttons,
  a full-palette toggle, and a demoted secondary affordance (§0.8), so the original "deliberately
  minimal" framing is softer than it was, but still holds in spirit: no onboarding links, no nags,
  only goal-relevant controls. If onboarding discoverability turns out to suffer, that's a
  fast-follow design question, not a day-one build item.
- **Remembering the user's last-chosen goal or mode (goal-first vs full-palette) across launches**
  (2026-10-20). Kevin explicitly ruled every cold launch defaults to goal-first + Free Overnight
  (§0.8.8) — simplicity over personalization for v1. A "remember my last choice" preference is the
  obvious fast-follow once real usage data exists on which goal people actually pick most.
- **A density-aware "smart default" goal** (2026-10-20) — e.g., auto-suggesting Park & Forget when
  the visible viewport has an unusually high rate of multi-day-clear blocks, or Free a Few Hours
  during midday on weekdays. Interesting, but needs real usage data this spec has no way to
  generate yet; Free Overnight as a static default is the honest, defensible v1 choice.
- **A fourth, custom "name your own window" goal button** (2026-10-20) — explicitly ruled out by
  Kevin; the power-user path (§0.8.9) already covers this via full-palette mode's clock icon. Not
  revisited unless Kevin asks.
- **A metered-tolerant variant of "Free a few hours"** (noticed while speccing §0.8.4/§0.8.5,
  2026-10-20) — today's strict `isFree(..., ignoringMeteredPayment: false)` disqualifies a
  perfectly fine metered spot from matching "Free a few hours" just because it requires payment.
  An errand parker might be totally happy to feed a meter. Not changed here because it's a
  genuinely separate product question (does this goal mean "zero required action" or "legal if I
  pay") that Kevin hasn't ruled on — flagging rather than silently picking one.
- **A lighter-weight "is the phone moving at all" pre-check before Phase 2's full motion-detection
  service** (e.g., using `CMMotionActivityManager` instead of GPS-speed-only) — would reduce the cost
  of detecting motion onset without first paying for a GPS fix, but is a genuinely separate research
  question from this spec's scope and isn't needed to ship Phase 1 or even a first cut of Phase 2.
- **Any change to how Drive Mode's destination-mode entry (the separate "enter an address" flow)
  is reached.** Out of scope entirely — Kevin's ruling is specifically about the destination-less
  Cruise case being the default; destination-mode Drive Mode keeps its existing entry point
  (reachable from the pulled-up search sheet, unchanged) and is untouched by this spec.
- **A richer "nearby free blocks" ambient summary** (e.g., "3 free blocks within 500m" text under
  the pill, before the user even taps it) — would make the ambient screen more informative at a
  glance but requires a spatial query over loaded segments that doesn't exist today. Noted because
  it's the natural next ask once this ships; not pre-built here.

---

*Spec written by @tech-lead, 2026-10-19. Amended by @tech-lead, 2026-10-20 — §0.8 (goal-first) is
now the centerpiece; the amendment banner right after the header and the "Open decisions for Kevin"
list inside it are the five things to rule on before dispatch. §0 (original) is otherwise still the
part Kevin needs to read and rule on; everything after it is the detail backing those rulings. The
"single biggest risk" callout at the top is not decorative — re-read it before writing any
`ContentView.swift` code against this spec. Re-read §0.8.2's ASP-side-swap framing before writing
any "Free overnight" code — it is not "now → tomorrow 8am," and treating it that way is the exact
mistake this amendment exists to prevent.*
