# Drive Mode as the default opening experience — destination-less Cruise home screen

**Status:** Spec draft, 2026-10-19. Not started. Kevin's ruling on §0's decision list is required
before any engineering is dispatched — this is the opening screen for 100% of users, the highest-
blast-radius UI change in the project's history.
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
- **One ambient primary affordance**: a single pill/button, reusing the already-Kevin-approved
  copy "Find a Spot" (`BrowseNavigationSheet.swift:34-39`, §0f ruling) unless Kevin wants to rename
  it to "Parking Near Me" per his verbatim framing — trivial either way, @designer's call (§0.1a).
  Tapping it calls the existing `enterCruiseMode()` (`ContentView.swift:3036-3045`) **unchanged** —
  this is the one and only escalation trigger in Phase 1 (§0.5 covers auto-escalation as a later
  phase).

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
| **A — "hunt a spot where I am now"** | Sheet already open, competing with search field for attention → tap "Find a Spot" (1 tap, but curb colors are partially obscured by the sheet until that tap) | Curb colors + location already fully visible at open, zero obstruction → tap the ambient pill (1 tap). **Net: same tap count, strictly better glance-value** — this is Kevin's actual ask. |
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

- `AppConstants.driveModeDefaultEnabled` — Phase 1: ambient home screen default + manual-tap
  escalation + persistent Search icon + permission priming + the `enterCruiseMode()` auth-request
  fix (§0.2). Dark-ships `false`; guard tests assert `activeSheet` still defaults to `.browseNav`
  and `dismissTargetOutsideBrowseNav` still resolves to `.browseNav` when the flag is off — zero
  behavior change for existing users until flipped.
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
- **Open item #18 (overnight "sea of green" nudge, not started):** currently speced as an "evening
  browse nudge" fired from inside the browse sheet (`docs/open-items.md` row 18). With the sheet
  demoted to pull-up (§0.4), a nudge that depends on the sheet being visibly open in the evening
  won't reliably surface. **Re-targeting note for whoever builds #18 next: attach it to the ambient
  home screen directly** — a dismissible banner in the same `safeAreaInset` family as the ASP
  banner (`ContentView.swift:2037`), not inside the sheet. Small re-target, not a redesign; flagging
  now so it isn't rediscovered as a surprise later.

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

---

## §2 — Scope

### 2.1 In scope (Phase 1 — `driveModeDefaultEnabled`)

1. Flip the home screen's rest state from a default-open `.browseNav` sheet to no sheet
   (`activeSheet == nil`), with the ambient primary "Find a Spot" pill always visible when at rest.
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
- Open item #18's actual build — only its attachment point is re-targeted here, as a note for its
  own future spec/PR.
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
| `ios/WePark/WePark/ContentView.swift` | `activeSheet` default (`:483`), `dismissTargetOutsideBrowseNav` (`:1248-1251`), new ambient-pill view (new, small), new persistent Search icon (new, small, same family as `recenterButtonStack`), `enterCruiseMode()` auth-request fix (`:3036-3045`), first-launch priming card wiring, flag reads. | **High** — this is the file with the project's single worst regression history (#31 and its three-PR re-landing trilogy). Mandatory live-UI smoke, both flag states, both pre/post dismiss-target flip. |
| `ios/WePark/WePark/Views/BrowseNavigationSheet.swift` | Presentation-configuration rework: from permanent/non-dismissible to normal on-demand sheet. Content (search field, "Find a Spot" button, "New to parking?" link) unchanged. | Medium — real behavior change to how the sheet is hosted, even though its content doesn't change. |
| `ios/WePark/WePark/Services/LocationService.swift` | No internal change required — `requestAndFetchLocation()` is reused as-is. (The fix in §0.2 lives in `ContentView.swift`'s `enterCruiseMode()`, not here.) | None — included for completeness, not touched. |
| New: `ios/WePark/WePark/Views/LocationPrimingCard.swift` (or similar) | One-shot card, `BackgroundNoteGate`-style persistence. | Low — new, additive, no existing call sites. |
| New: `ios/WePark/WePark/Services/Constants.swift` | Add `driveModeDefaultEnabled` flag constant. | Low — mechanical, follows `communityEnabled`/`regularsEnabled` precedent exactly. |

**Do NOT touch for Phase 1:** `MapViewRepresentable.swift` (the heading-up/zoom/puck/overlay stack
is reused unchanged — the ambient posture needs none of it; the escalated posture already has it).
`DrivingContextService.swift`, `CruiseVoicePolicy.swift`, `FinalApproachService.swift` — all
untouched.

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
| **DM-2** — Ambient pill + persistent Search icon + `BrowseNavigationSheet` presentation rework | @ios-engineer | DM-1 (reads the flag/rest-state) | 1–1.5 sessions |
| **DM-3** — First-launch priming card + `enterCruiseMode()` auth-request fix + denied-state copy/Settings link | @ios-engineer | Can run in parallel with DM-2 (different code surfaces — card is new, auth fix is a small addition inside `enterCruiseMode()`) | 1 session |
| **DM-4** — Live-UI smoke (both flag states) + QA pass | @qa-verifier | DM-1–3 merged | 1 session |
| **@designer** — ambient pill copy/icon, Search icon placement, priming-card copy | @designer | Runs in parallel with DM-1–3, non-blocking | — |

**Phase 1 total: ~3.5–4.5 engineering sessions + 1 QA session, plus Kevin's own manual smoke**
(irreducible for camera/default-screen changes per this project's own established lesson —
`HANDOFF.md`'s W8.5c-polish-PR-3 entry: "for camera/animation changes, Kevin's manual smoke is
irreducible verification"). Call it **5–6 sessions wall-clock**, consistent with "guess + buffer"
honesty for a change of this blast radius.

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

---

## §6 — Out-of-scope follow-ups (noticed, explicitly punted, with rationale)

- **Renaming "Find a Spot" to "Parking Near Me."** Kevin's verbatim framing uses "parking near me";
  the shipped copy is "Find a Spot" (§0f ruling, already Kevin-approved once). Trivial either way —
  left to @designer's pass rather than pre-decided here, so it doesn't block engineering dispatch.
- **Removing the FT-20 sheet's "New to parking?" link from the pulled-up sheet, or promoting it to
  the ambient screen.** Not requested, not implied by Kevin's framing — the ambient screen is
  deliberately minimal (one pill, no secondary links) per §0.1's "no nagging" instruction. If onboarding
  discoverability turns out to suffer, that's a fast-follow design question, not a day-one build item.
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

*Spec written by @tech-lead, 2026-10-19. §0 is the part Kevin needs to read and rule on; everything
after it is the detail backing those rulings. The "single biggest risk" callout at the top is not
decorative — re-read it before writing any `ContentView.swift` code against this spec.*
