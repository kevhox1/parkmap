# Community 2.0 Phase 4b (iOS push + relevance router + WP5) — QA Pass 1 — 2026-09-03

**Reviewed:** PR #101, branch `ios/community-phase4b` @ `ef3efe11`, against `origin/main` @ `8e42a5bb`,
per `docs/community-2.0-reconciliation-spec.md` §2.9 (as amended, PR #100) + §3 Phase 4 +
`docs/community-2.0-roadmap.md` S12 row + the live backend (`supabase/functions/send-community-push/index.ts`,
`supabase/03-community-2.0-schema.sql`).

**Verdict: FIX-THEN-MERGE.** One well-evidenced blocking bug in the token-upsert request (defeats an
explicit acceptance criterion silently, cheap to fix). Everything else — the privacy gate, environment
stamping, the shared relevance predicate, completion-handler discipline, copy verbatim, and the WP5
presentation judgment call — reads correct on a cold, adversarial read. Full TestFlight gate ceremony
below; this is the "Kevin's Mac gate" writeup requested.

## Summary

The core architecture is sound and the privacy invariant (server never learns a parked blockface) holds:
`ParkedCarSegmentReader` duplicates `ParkPinService`'s exact storage key/envelope shape correctly, the
comparison is 100% on-device, and the only thing ever uploaded is `(user_id, apns_token, environment,
zone_id)` — verified against the token-payload unit test and the live Edge Function's actual read query.
`CommunityPushRelevance` is genuinely one shared pure function wired into both the background
`AppDelegate` path and the foreground `ContentView.updateConfirmPromptCandidate` path (grep-confirmed,
not just claimed), with correct `.noData`/`.newData` completion-handler discipline. The WP5 card's
"floating overlay, not modal sheet" judgment call is the right read of the prototype (verified verbatim
against `prototype.html:104-113`, which is itself an absolutely-positioned floating card above the
sheet, not a modal). The 26 tests are real, behavior-asserting, and independently counted (26 `func
test` matches the file's own inventory).

The one blocking finding: `PushRegistrationService.upsertToken`'s POST to `device_push_tokens` never
supplies an `on_conflict` query parameter, but the table's primary key (`id`, server-generated,
never present in the payload) is *not* the constraint the upsert is supposed to target — the schema's
actual `unique (user_id, apns_token)` constraint is. Per PostgREST's documented default (missing
`on_conflict` → conflict target defaults to the primary key) — independently corroborated by this
repo's own `ingest-film-permits/index.ts`, whose comment explicitly documents needing `on_conflict` for
exactly this reason — the very first token registration will succeed, but every subsequent upsert for
the same device (zone change, app foreground, relaunch) will hit a real Postgres unique-constraint
violation on `(user_id, apns_token)` that `ON CONFLICT (id)` does not catch, and fail. The failure is
swallowed silently (`catch { /* best-effort */ }`), so "re-upsert on zone change" — an explicit
acceptance criterion in both the spec and this PR's own description — silently never works again after
a device's first-ever registration. This does not break the privacy boundary itself (segment/location
is never uploaded either way), but it does mean a device's `zone_id` on the server gets stuck at
whatever it was on first registration, which defeats the entire point of zone-scoped push targeting
for any user who parks in a second zone.

## Acceptance criteria checklist (from the PR description)

- [x] Flag-gated end-to-end — verified by reading every call site: `requestRegistrationIfEnabled`,
      `didReceiveDeviceToken`, `updateZone`, `handleAppForeground` all internally guard on
      `AppConstants.communityEnabled`; `AppDelegate.didReceiveRemoteNotification` guards first thing;
      `confirmPromptOverlay` and `updateConfirmPromptCandidate`'s call site both guard on the flag too.
      Flag is `false` on this branch (`Constants.swift:154`) — genuine no-op confirmed by code reading.
- [x] Environment stamping mechanism + documented failure mode — verified `parse(profileString:)`
      against all four branches (dev/prod/nil/malformed), all fall back to `.production` except an
      actual `development` value; matches the three real-world cases correctly (see Finding area 2
      below). Tests cover all four branches.
- [ ] Token upsert keyed on `(user_id, apns_token, environment, zone_id)`; **re-upsert on zone
      change/foreground — FAILS after the first successful write.** See Finding #1 (Blocking).
- [x] Silent-push handler: parses payload correctly (matches the live `send-community-push` payload
      shape exactly — `pin_type`/`segment_id`/`pin_id`/`zone_id`, no author/no lat-lng), compares
      on-device only, correct `.noData`/`.newData` discipline at every branch.
- [x] WP5 confirm-prompt card: copy verified verbatim against `prototype.html:104-113` (only the live
      `confirmCount` substitutes for the mockup's static "148", as intended); shared predicate with the
      push path (grep-confirmed one function, two call sites); cross-path dedupe via
      `CommunityPushDedupeStore`, backed by UserDefaults, tests cover mark/trim/malformed-entry-skip.
- [x] Tests added for all five listed areas, count independently verified: 26 `func test` in the file,
      matching the header's own inventory line-for-line.

## Findings

### 🔴 Blocking

- **#1: `device_push_tokens` token upsert doesn't target the table's actual unique constraint —
  every upsert after the first for a given device silently fails**
  - Where: `ios/WePark/WePark/Services/PushRegistrationService.swift:557-572` (`upsertToken`)
  - What: The POST to `rest/v1/device_push_tokens` sets `Prefer: resolution=merge-duplicates,
    return=minimal` but the request URL carries no `on_conflict` query parameter, and the JSON body
    (`tokenUpsertPayload`) never includes `id`. `device_push_tokens.id` is `uuid primary key default
    gen_random_uuid()` (`supabase/03-community-2.0-schema.sql:535`) and the real dedupe target is a
    *separate* constraint, `unique (user_id, apns_token)` (line 542). Per PostgREST's documented
    default — when `on_conflict` is omitted, the generated SQL is `INSERT ... ON CONFLICT (<primary
    key columns>) DO UPDATE` — this compiles to `ON CONFLICT (id) DO UPDATE`. Since `id` is
    server-generated fresh on every INSERT attempt (never supplied by the client, never actually in
    conflict), that ON CONFLICT clause never fires, and the underlying INSERT instead hits the
    `unique (user_id, apns_token)` constraint as an ordinary, un-caught `23505` unique-violation error
    (Postgres only suppresses a conflict on the *exact* constraint named in `ON CONFLICT`, not a
    different one that happens to also be violated).
  - Independent corroboration in this exact repo: `supabase/functions/ingest-film-permits/index.ts:507-518`'s
    own comment explicitly documents this exact PostgREST behavior ("Supabase JS v2
    `.upsert(..., { onConflict: 'expression' })`... PostgREST 12+ resolves named indexes by index
    name... if on this project [it] doesn't support index-name resolution, fall back to a raw SQL
    RPC") — a previous session on this codebase already had to reason through the identical
    conflict-target-must-be-explicit gap for a different table.
  - Effect: first-ever registration for a device succeeds (nothing to conflict with yet). Any
    subsequent call — zone change (parked-car move, `.onChange(of: parkPinService.currentUpdatedAt)`),
    app foreground (`handleAppForeground`), or a relaunch that resolves to the same token but a
    different zone — calls `attemptUpsert()` → `upsertToken` → gets a non-2xx response → the `catch`
    block on line 580 silently swallows it (`// Best-effort — the next zone change / foreground /
    relaunch retries naturally, since attemptUpsert's dedupe only skips when the LAST upload
    SUCCEEDED`) → `lastUploaded` is never updated → the server's copy of `zone_id` is permanently
    stuck at whatever the device's very first registration resolved to. A user who registers while
    parked in Nolita, then later parks in SoHo, will keep receiving (or not receiving) pushes scoped
    to Nolita forever, with zero client-visible symptom.
  - Also untested: `PushRegistrationServiceTests.swift` only asserts on `tokenUpsertPayload`'s output
    dictionary (the JSON body shape) — nothing exercises `upsertToken`/`attemptUpsert`'s actual
    `URLRequest` construction. This codebase already has a reusable request-interception harness for
    exactly this (`PinMockURLProtocol`, `WeParkTests/CommunityPinServiceTests.swift:1092+`), and
    `PushRegistrationService`'s `urlSession` is already injectable — the harness was available and not
    used, which is why this didn't surface in the 26 tests.
  - Expected: the request should carry `?on_conflict=user_id,apns_token` (matching the schema's real
    unique constraint) so a second upsert for the same device actually updates the existing row's
    `environment`/`zone_id` instead of erroring.
  - Repro (cheapest real confirmation, no Xcode needed): once the migration is live, curl the same
    two-call sequence — POST once (succeeds, 201/204), POST a second time with the same `user_id` +
    `apns_token` but a different `zone_id` (same `Prefer` header, same missing `on_conflict`) and
    check the second response status. Expect a `409`/`23505` on the second call if this analysis is
    correct; this is a 2-minute check against the already-live table, no Xcode required, and mirrors
    the `scripts/test-community-2-schema.sh` curl-smoke pattern this repo already uses for schema
    verification.
  - Fix: append `on_conflict=user_id,apns_token` to the request URL in `upsertToken`, and add a
    `PinMockURLProtocol`-style test asserting the outgoing request URL contains it (proves the fix and
    closes the coverage gap that let this ship).
  - Owner: `@ios-engineer`

### 🟡 Significant

- **#2: Zone re-derivation is not actually wired to app-foreground, despite being claimed**
  - Where: `ContentView.handleScenePhaseChange` (`.active` branch) vs. `updatePushZoneFromParkedCarOrLocation`'s
    three real call sites.
  - What: The PR description states zone is "Re-derived on parked-car change
    (`.onChange(of: parkPinService.currentUpdatedAt)`), location update, launch, and foreground." Grep
    confirms `updatePushZoneFromParkedCarOrLocation()` is called from exactly three places:
    `.onChange(of: parkPinService.currentUpdatedAt)`, `handleLocationUpdate()`, and
    `performLaunchSetup()`. The foreground branch (`handleScenePhaseChange`, `.active` case) only calls
    `pushRegistrationService.requestRegistrationIfEnabled()` and `.handleAppForeground()` —
    `handleAppForeground()` re-attempts an upload using the *existing* `currentZoneId`, it does not
    recompute it from fresh parked-car/location state.
  - Expected (per the PR's own description and the spec's intent): foregrounding after the app has
    been backgrounded across a zone boundary should refresh `zone_id` before the next upload attempt.
  - Impact: bounded but real — in practice a location fix likely follows shortly after foreground
    (which does call the zone-recompute via `handleLocationUpdate`), so this is probably a short delay
    rather than a permanent staleness, but it's a description/implementation mismatch worth closing:
    either add the call to the foreground branch, or correct the PR description's claim.
  - Owner: `@ios-engineer`

- **#3: TestFlight gate procedure (both this PR and the S11 roadmap note) doesn't cross-reference the
  required server-side `APNS_ENV` secret flip — a silent-failure trap**
  - Where: PR #101's "TestFlight-with-flag-on procedure" section; `supabase/functions/send-community-push/index.ts:37-39,
    247-259`.
  - What: `send-community-push` filters `device_push_tokens` by `.eq("environment", apnsEnv)` and
    defaults `APNS_ENV` to `'sandbox'` if the secret is unset. TestFlight-provisioned tokens stamp
    `environment = 'production'` (per this PR's own, correct `APNSEnvironment.detectCurrent()` logic —
    App Store Connect strips `embedded.mobileprovision`). The S11 roadmap row already flags this
    ("⚠️ S12 note: TestFlight uses the production APNs environment... `APNS_ENV` flips to `production`
    for the TestFlight phase") but this PR's own TestFlight procedure section (Option A/B) discusses
    only the iOS-side flag and never repeats or links to that requirement.
  - Impact: if Kevin runs the TestFlight gate using only this PR's own procedure without separately
    recalling the S11 roadmap note, `send-community-push` will keep querying for `environment =
    'sandbox'`, find zero rows, and silently send 0 pushes — same "compiles, runs, never receives push,
    no error" trap class this spec explicitly called out for the APNs entitlement/`.p8` setup.
  - Expected: this PR's TestFlight procedure section should explicitly include "flip the `APNS_ENV`
    Supabase secret to `production` before/at the same time as the TestFlight archive," not leave it
    to cross-document recall.
  - Owner: `@ios-engineer` (doc fix) / Kevin (the actual secret flip, per the standing "Kevin applies
    Supabase config himself" convention) — see the full gate ceremony below, which folds this in as a
    required step.

### 🟢 Minor / nit

- **#4:** `AppDelegate.didReceiveRemoteNotification`'s `UNUserNotificationCenter.current().add(request)
  { error in ... completionHandler(.newData) }` (`WeParkApp.swift:253-258`) calls `completionHandler(.newData)`
  unconditionally inside the `add` completion, even on the (rare) branch where `add` itself errors and
  no notification was actually enqueued. `UIBackgroundFetchResult` is informational (affects background
  execution scoring, not correctness), so this is cosmetic — but `.noData` would be more accurate on the
  error path. Not worth a blocking fix.
- **#5:** `CommunityPushDedupeStore` marks a pin "seen" in the background push path (`WeParkApp.swift:238`,
  before the `UNUserNotificationCenter.add` call) and in the foreground WP5 path
  (`ContentView.updateConfirmPromptCandidate`, before the card is shown) — both *before* confirming
  the user-visible surface actually succeeded/was seen. If `add(request:)` fails (very rare — e.g. a
  malformed identifier, which can't happen here since it's UUID-based), the pin would be marked "seen"
  with no notification ever having appeared, and would also never re-trigger the WP5 card. Same
  "informational, not correctness-critical" bucket as #4 — flagging for awareness, not requiring a fix.

### 💡 Out of scope (logged, not fixed)

- `CommunityPinService.upsertVote`/`upsertProfile` (existing, unmodified by this PR) appear to have
  the *same* missing-`on_conflict` shape Finding #1 describes for `votes`' `unique(pin_id, user_id)`
  constraint (that table's PK is a `bigserial id`, not `(pin_id, user_id)` — same mismatch pattern).
  `upsertProfile` happens to be safe because its payload explicitly includes `id` (the real PK), so its
  default-to-PK behavior is correct by coincidence. `upsertVote` looks like it could have the identical
  live bug this PR's new code copies — but that file is explicitly out of this PR's scope (per the PR's
  own "Not touched" list) and was presumably already shipped/tested in an earlier phase. **Recommend a
  fast, cheap live check** (same two-POST curl sequence as Finding #1's repro) against the *already
  deployed* `votes` table — if "Still there"/"Gone" vote-changing is silently broken in production
  today, that's a bigger, independent, currently-shipping bug this QA pass surfaced as a side effect,
  not something for this PR to fix. Flagging for `@backend-data`/`@ios-engineer` to verify separately.

## The privacy gate — traced end-to-end (spec §2.9 / AC-P4.3)

- **On-device comparison, not server-side:** `ParkedCarSegmentReader.currentSegmentId()` reads
  `NSUbiquitousKeyValueStore.default` directly, under the exact same key
  (`"wepark_synced_car_state"`) and envelope shape (`SyncedCarEnvelope`, `.parked`/`.cleared`) that
  `ParkPinService` uses — verified against `Services/ParkPinService.swift:103,142,282,332` and
  `Models/SyncedCarEnvelope.swift:36-40` directly, not just the doc comment's claim. No drift.
- **Upload payload:** `tokenUpsertPayload` — verified by the one unit test that asserts `payload.count
  == 4` and only `user_id`/`apns_token`/`environment`/`zone_id` — matches §2.9's stated contract
  exactly. `zone_id` is derived via the already-shipped, already-coarse `CommunityZoneBounds.zoneId(forLat:lng:)`
  helper (same one `CommunityPinService`/`CrewFeedSection` already use) — no new precision leak
  possible; it returns the same three-zone bucket the UI already publicly shows.
  device with a matching parked segment, silence for a non-matching one.
- **Server-side payload contract:** cross-checked `send-community-push/index.ts`'s actual outgoing
  APNs body (`{ aps: {"content-available":1}, pin_type, segment_id, pin_id, zone_id }`, lines
  238-244) against `AppDelegate`'s parsing (`WeParkApp.swift:198-207`) — field names and types match
  exactly. The server never sends `author_id`, never sends lat/lng — confirmed by reading the actual
  deployed function, not assuming the PR description's paraphrase.
- **Completion-handler discipline:** every early-exit branch in `didReceiveRemoteNotification` (flag
  off, malformed payload, not relevant, already-seen, unrecognized/no-copy type) calls
  `completionHandler(.noData)`; only the branch that actually calls `UNUserNotificationCenter.add`
  eventually calls `.newData`. Correct.

## Environment stamping — traced against the three real cases + a fourth

- **Xcode dev build → sandbox:** `parse` returns `.sandbox` only when `Entitlements.aps-environment ==
  "development"` is found in a present, parseable plist. Correct.
- **TestFlight / App Store → production (file absent):** confirmed — Apple strips
  `embedded.mobileprovision` from every App Store Connect distribution build; `profileString == nil`
  hits the `guard` and falls to `production` immediately. This matches Apple's actual, documented
  distribution behavior (not something I can execute here, but it's a well-established, unambiguous
  platform fact, and the PR's own doc comment states it correctly with the right reasoning).
- **Simulator:** same "absent" branch — harmless, since `registerForRemoteNotifications()` never
  succeeds on Simulator anyway (no token is ever generated to mis-stamp). Confirmed no special-cased
  simulator handling exists or is needed.
- **Fourth case — corrupted/malformed present file:** also falls to `.production` (the `guard let
  plistData = ... as? [String: Any] ... entitlements["aps-environment"] as? String` chain fails
  closed). This is the *safer* failure direction given how the backend actually filters
  (`send-community-push` queries `.eq("environment", apnsEnv)` where `apnsEnv` defaults to
  `'sandbox'` today but will be `'production'` during the TestFlight phase per Finding #3) — a
  wrongly-`.sandbox`-stamped real device would never receive a production-environment fan-out at all
  (silent, permanent miss), whereas a wrongly-`.production`-stamped one at worst gets excluded from a
  sandbox-environment test fan-out during internal dogfooding, which is the lower-stakes miss. Tests
  cover this branch explicitly (`testParse_malformedProfileString_returnsProduction`).

## Registration flow

- **Flag-gated completely:** traced every call site (`requestRegistrationIfEnabled`,
  `didReceiveDeviceToken`, `updateZone`, `handleAppForeground`, plus the `AppConstants.communityEnabled`
  guards around each `ContentView` call site) — with the flag off, `UIApplication.registerForRemoteNotifications()`
  is never called anywhere in the diff. Genuine no-op.
- **Permission reuse:** `requestRegistrationIfEnabled` only calls `getNotificationSettings` (a read) and
  conditionally `registerForRemoteNotifications()` if already `.authorized`/`.provisional` — never
  presents a system or in-app prompt itself. The one call site that follows an actual permission grant
  is `NotificationRationaleView`'s existing `onPermissionGranted` callback. No new prompt introduced.
- **Token-buffer race (the one this task explicitly asked about):** traced the causality chain and
  found this is *not* a real race, unlike the `pendingDeepLinkCarID` precedent it mirrors.
  `pendingDeepLinkCarID` needs its extra `handleScenePhaseChange` drain because a notification tap can
  arrive while the app is cold-killed (before `ContentView` exists at all). `pendingDeviceToken` can
  only ever be set as a *result* of a `registerForRemoteNotifications()` call this codebase only ever
  makes from inside `ContentView`'s own lifecycle (`onPermissionGranted`, `performLaunchSetup`,
  foreground) — meaning `ContentView` (and its `.onChange(of: appDelegate.pendingDeviceToken)`
  modifier) is guaranteed to already exist before a token can possibly arrive. No missing
  foreground-drain call site is needed here the way it was for the deep link. Verified, not assumed.
- **Re-upsert on zone change/foreground:** claimed but **broken** — see Finding #1 (the on_conflict bug)
  and Finding #2 (foreground doesn't actually recompute zone).

## Relevance predicate + copy

- One shared pure function (`CommunityPushRelevance.isRelevant`), two call sites — grep-confirmed:
  `AppDelegate.application(_:didReceiveRemoteNotification:...)` (`WeParkApp.swift:215`) and
  `ContentView.updateConfirmPromptCandidate` via `firstUnseenSweeperPassedMatch` (which itself calls
  `isRelevant` internally) — genuinely the same S9-lesson-respecting shape the PR claims, not two
  divergent copies.
- Per-type behavior verified against both the code and its tests: `sweeperPassed`/`enforcementActive`
  notify on segment match; `openSpot`/`leavingSoon` never notify even on an exact segment match
  (explicit test coverage, `testIsRelevant_openSpot_ownBlockMatch_false` /
  `testIsRelevant_leavingSoon_ownBlockMatch_false`).
- Copy verified against `docs/community-1.0-direction.md` §6's compliance framing (no ticket-avoidance
  language) and enforced by a real test (`testNotificationCopy_enforcementActive_hasMoveOrFeedMeterCopy_noAvoidLanguage`,
  which actually scans for "avoid"/"ticket"/"fine"/"evasion"/"dodge" as substrings — a real assertion,
  not a vibe).
- Dedupe by `pin_id` across both paths: `CommunityPushDedupeStore` is UserDefaults-backed (survives
  backgrounding/relaunch between the two paths, which an in-memory `Set` would not), constructed fresh
  in `AppDelegate` and held as a `ContentView` `private let` — both point at the same UserDefaults key
  (`"wepark_community_push_seen_pin_ids"`), so they really do share state. Verified by reading the
  `defaultsKey` constant is a single hardcoded string used by both construction sites, not two
  independently-keyed stores that happen to look similar.

## WP5 card — presentation judgment call

Read the gap inventory's framing and the prototype directly rather than trusting the PR description's
characterization of either. `prototype.html:104-113` renders the confirm card as
`position:absolute; ... bottom:{{promptBottom}}px; z-index:9` — an **absolutely-positioned floating
card layered above the bottom sheet** (`z-index:20` for the sheet itself), not a modal takeover. The
PR's reading — floating overlay via the existing `spotPlacementConfirmOverlay`/`parkingGuidePromptBanner`
family, not a new `ActiveSheet` case — matches the prototype's actual literal behavior, independent of
how the gap-inventory's prose is interpreted. **Ruling: the PR's judgment call is correct, not just
defensible.** If anything, a modal `.sheet(item:)` would have been the *wrong* read of the prototype.

- "Confirm — it passed" routes to the exact existing `upsertVote(.confirm)` + `callExtendPinExpiry`
  pair `PinDetailSheet.ReactionsRow.handleStillHere` uses — verified both call sites use identical
  method signatures against `CommunityPinService.swift:1631,1786`. No new write path.
- "Didn't see it" dismisses only, no vote, no re-prompt — dedupe is recorded at *card-show* time
  (`updateConfirmPromptCandidate` marks seen before setting `confirmPromptPin`), not at
  confirm/dismiss time, so this is correct regardless of which button is tapped or if the app is
  backgrounded mid-card.
- No engagement-bait: copy is purely informational/compliance-framed, no streaks/points/badges
  language anywhere in the card.

## Tests (26)

Independently counted: 26 `func test` matches the header's own inventory exactly. All are real,
behavior-asserting XCTest assertions (not `XCTAssertTrue(true)`-style placeholders) — spot-checked
every one while reading. Coverage gaps found:

- Environment parse: all four branches covered, including the load-bearing absent-file case
  (`testParse_nilProfileString_returnsProduction`) and the malformed case. Good.
- Dedupe: covers mark/idempotent-mark/bounded-trim/malformed-entry-skip. Good — this is the one area
  with genuinely thorough edge-case coverage.
- Copy audit test is real: `testNotificationCopy_enforcementActive_hasMoveOrFeedMeterCopy_noAvoidLanguage`
  actually substring-scans the combined title+body against five forbidden words. Not a rubber stamp.
- **Gap:** nothing tests `PushRegistrationService.attemptUpsert`/`upsertToken`'s actual `URLRequest`
  (URL, query string, headers) — only the pure `tokenUpsertPayload` dict-shape function is tested. This
  is exactly the gap that let Finding #1 ship; the fix should close it via the existing
  `PinMockURLProtocol` pattern.
- **Gap:** nothing exercises `attemptUpsert`'s dedupe-by-`lastUploaded` logic (does calling
  `updateZone` twice with the same zone actually skip the second network call?) — also only reachable
  via a request-interception test, same gap as above.

## TestFlight Option B recommendation — assessed

The PR recommends **Option B** (local, uncommitted flag flip at archive time, discarded after) over
**Option A** (throwaway branch). Assessed both honestly:

- **Option A (branch):** real advantages the PR's write-up undersells — git-history traceability of
  exactly what was archived (including the flag state), and zero working-tree-hygiene risk (a fresh
  branch checkout can't accidentally bundle in *other* uncommitted work). The PR's stated downside
  ("another branch to remember to delete") is real but low-stakes for a manual, Kevin-only, low-frequency
  ceremony — this isn't the agent-branch-hijack failure mode from the standing memory note (that's
  about *agents* left on a branch mid-session; this is a human doing one deliberate Xcode action).
- **Option B (local uncommitted flip):** lower ceremony, matches the `Config.xcconfig`
  never-commit-this-value precedent as the PR argues. But the PR's write-up is silent on two real
  failure modes this task specifically asked me to assess:
  1. **Other uncommitted changes riding along.** If Kevin's working tree has *any* other unstaged edit
     when he flips the flag and archives, that edit ships in the TestFlight build too, and `git checkout
     -- Constants.swift` afterward only reverts the flag — it does nothing about the other file. Needs
     an explicit `git status`/`git diff` check immediately before archiving.
  2. **The failure mode if the revert is forgotten is not neutral.** Unlike most "forgot to revert a
     local tweak" mistakes, forgetting `git checkout -- Constants.swift` means `communityEnabled = true`
     sits uncommitted in the working tree until Kevin's *next* unrelated commit — at which point a
     routine `git add`/`git commit` would silently ship the flag **enabled to `main`**, which the
     roadmap explicitly gates on the not-yet-complete build-18 drive test. This is a real, asymmetric
     risk the PR's write-up doesn't name.

**Recommendation: endorse Option B, but only paired with the explicit checklist below** — the PR's
"Option B" as described is directionally right but underspecified exactly where this task asked me to
look closely.

## The full TestFlight gate ceremony (spelled out end-to-end, for Kevin)

**0. Land the code fix first.** Finding #1 (the `on_conflict` bug) should be fixed and this PR
   re-verified (a fast pass — it's a one-line request-URL change plus one new test) before any of the
   below. Everything else in this report is either already-correct or non-blocking.

**1. Mac-side compile/test gate (this PR is [COMPILE-UNVERIFIED] — do this regardless of the TestFlight
   timing):**
   - `xcodebuild build` + `xcodebuild test -scheme WePark` with `communityEnabled` still `false` (the
     merged state) — expect the full suite green (this PR's own claimed 1180 = 1154+26).

**2. Pre-archive checklist (immediately before the flag-on TestFlight build):**
   - `git status` on `main`, confirm clean and up to date with `origin/main`.
   - Bump the build number via Xcode's normal mechanism and **commit that bump to `main` on its own,
     ordinary commit** — this keeps the shipped build number traceable to a real commit even though the
     flag bit itself won't be.
   - Locally edit `ios/WePark/WePark/Services/Constants.swift`: `communityEnabled = false` → `true`.
   - `git diff` — confirm the *only* uncommitted change is that single line. This is the check that
     closes Option B's "other uncommitted changes" risk.
   - Flip the `send-community-push` Edge Function's `APNS_ENV` secret to `production` (Supabase
     Dashboard or `supabase secrets set`, Kevin's own action per the standing "Kevin applies Supabase
     config himself" convention) — **required**, per Finding #3, or zero pushes will send with no error.

**3. Local test run with the flag flipped true (belt-and-suspenders — Archive itself does not run
   tests, confirmed):**
   - `xcodebuild test -scheme WePark` with `communityEnabled = true`.
   - Expect **exactly 3 known failures** per the roadmap's flagged 2026-08-28 note ("running the suite
     with `communityEnabled = true` fails 3 tests"). This PR's own 26 new tests call the pure
     `CommunityPushRelevance`/`APNSEnvironment`/`CommunityPushDedupeStore` functions directly and never
     reference `AppConstants.communityEnabled` — verified during this pass — so none of the 26 should be
     among those 3. If the failure count is anything other than 3, or a failure is in a file this PR
     touched, stop and investigate before archiving.

**4. Live-UI smoke with the flag on (mandatory — could not be performed in this Linux-only QA pass,
   and this PR touches `ContentView.swift`'s `mapZStack`, which is the mount-chain class this repo's
   own QA discipline treats as merge-blocking without it):**
   - Build + install on a sim or Kevin's physical device (physical device is required regardless for
     step 6, since push cannot be verified in Simulator).
   - Screenshot the map with the flag on. Confirm existing chrome (toolbar, ASP banner, Park Until
     pill, polylines) still renders unchanged — the new `confirmPromptOverlay` is appended, not
     interleaved with, the existing `mapZStack` content, and is itself conditionally empty
     (`@ViewBuilder if AppConstants.communityEnabled, let pin = confirmPromptPin`) whenever no matching
     pin exists, which is the common case — code-level regression risk reads low, but this needs an
     actual screenshot, not just this read, before Kevin trusts it live.
   - If reachable, trigger a `sweeper_passed` pin matching the parked car's segment and confirm the
     `ConfirmPromptCard` actually renders correctly above the sheet, buttons work, and it doesn't
     collide with any other overlay.

**5. Archive** (`Product > Archive` in Xcode) — confirmed does not run tests, safe regardless of step
   3's outcome.

**6. Upload to TestFlight.**

**7. Immediately after the archive completes:**
   - `git diff` once more to reconfirm nothing else crept in.
   - `git checkout -- ios/WePark/WePark/Services/Constants.swift` to discard the local flag flip.
   - `git status` — confirm clean.
   - **Before Kevin's next unrelated commit of any kind, re-run `git diff -- ios/WePark/WePark/Services/Constants.swift`
     as a habit** until this feature fully launches — the cheapest possible guard against the
     "flag ships enabled by accident on a routine commit" failure mode named above.

**8. Record a one-line breadcrumb** (HANDOFF.md or the roadmap doc): "TestFlight build `<N>` archived
   from `main@<sha>` with `communityEnabled` locally flipped true (Option B), discarded after archive" —
   so a future bug report against that specific TestFlight build number has a traceable provenance even
   without a dedicated branch.

**9. On-device AC-P4.3 verification** (per the roadmap S12 row: "Physical phone + SQL insert verifies
   AC-P4.3 — works outside NYC"): insert an `enforcement_active`/`sweeper_passed` pin matching the
   phone's parked segment via direct SQL insert (mirrors the S11 ceremony's own test-script pattern) —
   confirm a local, user-visible notification fires. Insert a second pin in the *same zone* but a
   *different* segment — confirm silent (push received per server logs, nothing surfaced to the user).
   This is the literal proof that the relevance gate works without the server ever learning the
   device's parked location — the privacy property this entire pipeline exists to uphold.

**10. Only after AC-P4.3 + the WP5 card are verified live, and separately after the build-18 drive
   test passes** (per the roadmap's own sequencing: "drive-test gate applies to the flag-flip... for
   external TestFlight testers," not to any merge) — expand beyond Kevin's own internal TestFlight
   install to external testers.

## What's working

- The privacy architecture is genuinely well-executed, not just well-documented: the on-device
  segment-comparison point (`ParkedCarSegmentReader`) is a byte-for-byte-correct duplicate of the
  actual shipped storage key/shape, not a divergent reimplementation that happens to compile.
- The shared relevance predicate is a real, single source of truth wired into both call sites — the S9
  lesson this codebase learned the hard way was actually applied here, not just cited.
- Copy is verbatim-verified against the prototype, and the "no avoid/ticket/fine/evasion/dodge"
  convention is enforced by an actual substring-scanning test, not a comment promising it.
- The WP5 presentation judgment call is correct against the prototype's literal rendering, not just a
  reasonable guess — good instinct to flag it explicitly anyway rather than deciding silently.
- Completion-handler discipline (`.noData`/`.newData`) is correct at every branch of the background
  handler — a common source of App Store review and background-execution-budget bugs, handled right.
- `nonisolated` discipline across every pure function is consistent and matches the project's own
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` precedent — this would have been a real compile-blocker
  class of bug (untestable from plain `XCTestCase`) if missed, and it wasn't.
- Xcode's file-system-synchronized groups (verified in `project.pbxproj`, `objectVersion = 77`) mean
  the three new Swift files don't need — and don't have — a separate pbxproj registration diff; not a
  gap.

## Smoke tests run

- Read every changed/new file in full (`PushRegistrationService.swift`, `ConfirmPromptCard.swift`,
  `WeParkApp.swift`'s diff, `ContentView.swift`'s diff, `PushRegistrationServiceTests.swift`) against
  the spec and the PR description, adversarially, not just for plausibility.
- Cross-referenced the live backend contract directly (`supabase/functions/send-community-push/index.ts`,
  `supabase/03-community-2.0-schema.sql`) rather than trusting the PR description's paraphrase of it —
  this is what surfaced Finding #1 and confirmed the payload-shape match.
- Verified model-layer consistency by grep (not assumption): `PinType` raw values, `CommunityPin.segmentId`/
  `.confirmCount`/`.pinType` property names, `CommunityZoneBounds.zoneId(forLat:lng:)`,
  `SupabaseAuthService.validAccessToken()`/`.currentUserId`, `CommunityPinService.upsertVote`/
  `.callExtendPinExpiry` — all match exactly, no drift between the new file and the services it calls.
- Balanced-brace sanity check on all four changed/new Swift files (no gross syntax break) — not a
  substitute for `xcodebuild`, which this Linux environment cannot run; explicitly noted as unverified
  below.
- Independently counted the new test file's `func test` occurrences (26) against its own header
  inventory (26) — match.
- Verified `docs/community-2.0-roadmap.md`'s S11/S12 rows directly for the APNs-environment note and
  the "3 failing tests" prerequisite, rather than trusting the PR description's summary of them.
- Read `design/prototype.html:90-118` directly for the WP5 card's actual markup/positioning, rather
  than trusting either the PR description's or the gap-inventory's characterization of it.
- **Not performed, and explicitly flagged as required before the TestFlight gate:** live-simulator/device
  build, install, and screenshot with `communityEnabled = true` — this environment has no Xcode/simulator
  toolchain (the PR itself is marked `[COMPILE-UNVERIFIED]` for the same reason). This PR touches
  `ContentView.swift`'s `mapZStack`, which is exactly the mount-chain class this repo's QA discipline
  requires a live screenshot for — folded into gate-ceremony step 4 above as mandatory before Kevin
  trusts the confirm-card renders correctly in practice.
- **Not performed:** the actual curl-based two-POST confirmation of Finding #1 against the live
  Supabase project (no credentials/access from this environment) — the finding is based on reading
  PostgREST's documented default behavior plus this repo's own corroborating precedent, not a live
  reproduction; flagged as the fastest way to confirm/deny before or instead of trusting this report's
  inference outright.
