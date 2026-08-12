# supabase-swift Adoption — Real WebSocket Realtime + Keychain Session Storage

**Feature:** Replace the 8s REST poll (and the raw-`URLSession` `SupabaseAuthService`) with real Supabase
Realtime over WebSocket via the `supabase-swift` SDK, so community pins (enforcement/sweeper/filming/
construction reports) push to other users in ~1–3s instead of up to 8s (and instead of being frozen
entirely during Drive Mode). Also migrates auth session storage from `UserDefaults` to Keychain.
**Owner:** Tech Lead (this spec) → **Phase 0 is Kevin's Mac**, then `@ios-engineer` (Streams A + B), in
sequence with FT-15 per §11.
**Created:** 2026-08-12.
**Status:** SPEC — awaiting Kevin review. **Sizing note up front: this is not "a few hours."** See §12 for
the independent estimate and why the old number is wrong.
**Related:** `docs/typed-pin-schema-spec.md` (the pin model this streams over), `docs/tier3-auth-and-reactions-spec.md`
§3.8/§3.9 (the write path this preserves unchanged), `docs/ft15-tf215-temporary-block-restrictions-spec.md`
(concurrent work on the **same file**, `CommunityPinService.swift` — §8.3 has the coordination plan).

---

## Read this first — decisions Kevin should confirm before engineering starts

Full reasoning in §13. Marked 🔴 items are the only ones I'd actually call blocking; everything else ships
on my recommendation if Kevin doesn't weigh in.

1. **Phase 0 (SPM dependency add) happens on the Mac, is a fully isolated commit with nothing else in
   it, and gates everything else.** §4 gives the exact Mac steps, in order, with a verification checkpoint
   before any Swift code is written against the SDK. This is the same hazard that stopped the prior attempt
   (`HANDOFF.md` "A3 SDK DEFERRED" entry, 2026-06-05) — I'm recommending a different, more disciplined path
   through it this time, not repeating the prior no-Xcode attempt.
2. **🔴 Sequencing vs. FT-15.** This spec's Stream B rewrites large parts of `CommunityPinService.swift` —
   the same file FT-15's Stream B3 (write path) and B4 (third fetch channel) are actively modifying right
   now (`HANDOFF.md` 2026-08-11 entry: PRs #69/#70/#71 open, B2–B4 queued next). I'm recommending Stream B
   **wait until FT-15's `CommunityPinService.swift` changes are on `main`**, not run in true parallel on the
   same file. See §11. Kevin should confirm this ordering, since it means Realtime doesn't land as fast as
   it could in isolation.
3. **Only `Auth` and `Realtime` SDK products get linked — not the `Supabase` umbrella, not `PostgREST`,
   not `Storage`, not `Functions`.** The REST read/write paths stay raw `URLSession`, unchanged (§8). This
   is a scope cut I'm making unilaterally to shrink the SPM dependency surface and the pbxproj diff; flag if
   you'd rather standardize on the SDK for REST too (I recommend against it — see §14).
4. **Keep the periodic REST poll alive as a low-frequency reconciliation fallback, not primary anymore.**
   Realtime becomes the primary freshness mechanism; the poll interval gets *lengthened*, not deleted. See
   §6.

---

## 1. Problem & User Story

**User story:** "I'm circling a block looking for a spot, or someone two blocks away just reported an
enforcement agent. I want to see that report on my map within a couple seconds — not up to 8 seconds late,
and NOT frozen entirely because I happen to be driving, which is exactly when I need it most."

**Why now — this is Kevin's framing, not a rediscovered nice-to-have:** flagged as a hard TF2 requirement
on 2026-06-06 (`HANDOFF.md`, Tier 3 go-live entry): *"time is crucial when it comes to parking"* — a lag on
"enforcement is on your block NOW" is the gap between moving your car and getting a ticket. It has been
deferred three times since (TF1 prep, Tier 3 sub-PR #1's SDK detour, and every TestFlight cycle since) and
is now the largest untouched item in the backlog.

**Current state, precisely (`ios/WePark/WePark/Services/CommunityPinService.swift`):**
- `startRealtime()` (lines 323–327) is a **no-op stub**. It has been a stub since Tier 1 (PR #37,
  2026-06-02) and is called once at launch (`ContentView.swift:2049`) and does nothing.
- The actual "live update" mechanism today is a periodic full re-fetch of the visible region every
  **8 seconds** (`pinRefreshIntervalSeconds`, line 141 — dropped from 25s in PR #43, `HANDOFF.md`
  2026-06-06 entry).
- That poll is **fully suspended during active Drive Mode** (`setDriveModeActive(true)` →
  `stopPeriodicRefresh()`, lines 254–265) — for battery reasons, at the exact moment fresh enforcement
  pins matter most (§7).
- The merge logic that would consume real Realtime events already exists and is already tested:
  `mergeRealtimeChange(pin:)` (lines 578–608) has 8 passing tests across
  `CommunityPinServiceTests.swift` (append/update/remove/expire, both Tier 1 open-data and Tier 3 crowd
  ephemeral types). **This spec does not touch that merge core** — it wires a real event source into it and
  adds the two things that core doesn't yet handle (§8.2).
- `SupabaseAuthService.swift` persists the anon-auth session in `UserDefaults` (header comment, lines
  16–21, explicitly flags this as a known gap: *"A fast-follow PR should migrate to Keychain when the SDK
  is added"*) — this is the QA nit referenced in the brief.

---

## 2. Scope — In / Out

### In
- Real WebSocket Realtime subscription on `public.pins`, replacing the `startRealtime()` stub, feeding the
  existing `mergeRealtimeChange`/new `removePin` merge functions (§8.2).
- Client-side viewport (bounding-box) gating on the merge path — a real gap in the current stub's own TODO
  comment, not previously identified (§8.2, §14).
- DELETE-event handling — a real gap the current merge signature doesn't cover at all (§8.2).
- Drive Mode: keep the Realtime socket open through Drive Mode; the periodic REST poll stays suspended
  during Drive Mode as it is today (Realtime replaces it, not "in addition to it") (§7).
- Reconnect on foreground, disconnect on background (new `scenePhase` branch) (§6.4).
- `SupabaseAuthService` internals swapped to the SDK's `Auth` client: Keychain-backed session storage
  (replacing `UserDefaults`), auto-resign on `.signedOut`. **Public API unchanged** — zero changes required
  in any caller (§9).
- The Mac-gated SPM dependency add itself, as an isolated, reviewed, verifiable step (§4).
- Retuned (lengthened, not deleted) periodic REST poll as a fallback/reconciliation mechanism (§6).
- A concrete plan for measuring battery/data impact, since that's the reason polling was suspended during
  Drive Mode in the first place (§10).

### Out
- Migrating the REST read/write paths (`buildOpenDataRequest`, `buildCrowdEphemeralRequest`,
  `insertCrowdPin`, `upsertVote`, `callExtendPinExpiry`) to the SDK's `PostgREST` client. Stays raw
  `URLSession`, unmodified by this spec (§8.1, §14 — explicit "don't do this now" flag).
- FT-15's own Realtime/fetch-channel work (Channel 3, `buildCrowdBlockScopedRequest`) — that's FT-15's
  scope; this spec's Realtime subscription is written to be **type-set-driven**, not hardcoded to today's
  two channels, so FT-15's new pin types slot in without a second Realtime-adoption pass (§8.3).
- Any backend/schema change. `public.pins` is **already** in the `supabase_realtime` publication
  (`supabase/02-pins-schema.sql:288–296`, applied to prod) — this is a pure client change plus one
  Mac-side build-system change. Zero SQL migration in this spec.
- Any PWA change. The PWA doesn't read `public.pins` at all (`docs/typed-pin-schema-spec.md` §11); this
  spec touches iOS + one build artifact only. The PWA's own `zone_messages` Realtime (already live,
  `supabase/01-mvp-schema.sql:109-112`) is untouched.
- Realtime for `zone_messages`/chat — that's PWA-only today and out of scope for a Kevin-is-iOS-only pass.
- `REPLICA IDENTITY FULL` on `public.pins` (would make DELETE payloads carry full old rows) — deliberately
  not requested; DELETE is handled by primary key only (§8.2), keeping the backend footprint at zero.
- Hand-rolled reconnect/backoff logic — the SDK's `RealtimeClientV2` manages this internally; this spec
  only reacts to its connection-status stream for UX/fallback-cadence decisions (§6.2).

---

## 3. Architecture

### 3.1 Codebases touched
- **iOS** (`@ios-engineer`, after Phase 0): the entire change. New files: `Services/RealtimePinChannel.swift`,
  `Services/RealtimeMergeGate.swift`, `Services/SupabaseClients.swift`. Modified:
  `Services/CommunityPinService.swift`, `Services/SupabaseAuthService.swift`, `ContentView.swift` (one new
  `scenePhase` branch, no camera/overlay surface touched), `WeParkApp.swift` (client construction).
- **Build system** (Kevin, Mac): `ios/WePark/WePark.xcodeproj/project.pbxproj` +
  new `Package.resolved`. See §4.
- **Backend:** untouched. See §2 Out.
- **PWA:** untouched. See §2 Out.

### 3.2 Current data flow (today)

```
ContentView.onAppear → pinService.startRealtime()             [no-op stub]
ContentView.onRegionChanged → pinService.onRegionChanged(region)
  → 800ms debounce → fetchPins(for: region)                   [REST, 2 channels, unchanged by this spec]
  → startPeriodicRefresh() (first call only)
      → every 8s: re-fetch lastFetchedRegion                   [the de facto "live update" mechanism]
      → suspended entirely while driveModeActive
insertCrowdPin() → optimistic append via mergeRealtimeChange   [only path that currently uses the merge core]
```

### 3.3 New data flow

```
WeParkApp.swift (once, app lifetime):
  authClient    = AuthClient(url: supabaseURL, ...)            [SDK, replaces raw URLSession auth calls]
  realtimeClient = RealtimeClientV2(url: ..., apikey: ...)     [SDK, new]
  → both injected into SupabaseAuthService / CommunityPinService

ContentView.onAppear → pinService.startRealtime()
  → subscribes ONE channel on public.pins, table-wide (no server-side bbox filter is possible —
    see §8.2 for why), postgres_changes INSERT/UPDATE/DELETE
  → each event flows through RealtimeMergeGate (NEW, pure, viewport + type-eligibility check)
    → passes  → mergeRealtimeChange(pin:) [existing, unchanged] / removePin(id:) [NEW]
    → fails   → dropped (out of viewport, or not a mergeable pin_type)

ContentView.onRegionChanged → pinService.onRegionChanged(region)   [UNCHANGED — still the only way
  → 800ms debounce → fetchPins(for: region)                          new-to-viewport pins get picked up;
                                                                        Realtime only pushes deltas, it
                                                                        can't backfill a fresh viewport]
  → startPeriodicRefresh()
      → every N seconds (retuned, §6.1): re-fetch lastFetchedRegion — RECONCILIATION FALLBACK,
        not primary; catches anything a dropped/reconnecting socket missed
      → still suspended during driveModeActive — Realtime IS the Drive Mode mechanism now (§7)

ContentView .onChange(of: scenePhase):
  .background → pinService.disconnectRealtime()                 [NEW]
  .active     → pinService.reconnectRealtime()                   [NEW]
                + one-shot re-fetch of lastFetchedRegion          [catches whatever was missed while
                                                                     backgrounded — belt-and-suspenders]
```

### 3.4 New / changed symbols

**New file — `Services/RealtimeMergeGate.swift`** (pure `Foundation` + `MapKit` for `MKCoordinateRegion`
only, no networking, matches the `DriveHeadingSnap.swift` house style of a framework-light pure-decision
file):

| Symbol | Purpose |
|---|---|
| `static func isWithinRegion(lat:lng:region:paddingFactor:) -> Bool` | Client-side viewport gate — Realtime has no server-side bbox filter (§8.2). Default `paddingFactor` slightly wider than the exact viewport (recommend 1.5×) so a pin just outside the visible edge doesn't pop in/out on every micro-pan. |
| `static let mergeablePinTypes: Set<PinType>` | Same set `mergeRealtimeChange` already hardcodes today (line 582) — pulled out to a named constant so FT-15's new types (§8.3) are a one-line addition in one place, not a re-derivation. |

**New file — `Services/RealtimePinChannel.swift`:**

```swift
/// Abstraction over the SDK's RealtimeChannelV2 so CommunityPinService — and its tests — never
/// depend on a live socket directly. Mirrors the RouteServicing protocol-extraction precedent
/// (ios/WePark/WePark/Services/RouteService.swift:47-58, W8.5c M-2).
protocol RealtimePinSubscribing: AnyObject {
    /// True while the underlying socket reports a connected state.
    var isConnected: Bool { get }
    /// Subscribes to INSERT/UPDATE/DELETE on public.pins. Safe to call redundantly.
    func connect(onUpsert: @escaping (CommunityPin) -> Void, onDelete: @escaping (UUID) -> Void) async
    /// Tears down the socket. Safe to call redundantly / when not connected.
    func disconnect() async
}

/// Real implementation — the only file in this feature that imports the SDK's Realtime product.
final class SupabasePinRealtimeChannel: RealtimePinSubscribing { ... }
```

A `MockRealtimePinChannel` (test target) lets `CommunityPinService`'s Drive-Mode/scenePhase
connect-disconnect *sequencing* be unit-tested without a live socket (§9) — the actual event delivery
still needs an integration/live check (§9).

**`CommunityPinService.swift` changes:**

| Symbol | Change |
|---|---|
| `startRealtime()` | No longer a no-op. Calls `realtimeChannel.connect(onUpsert:onDelete:)`, wiring both closures through `RealtimeMergeGate` into the existing `mergeRealtimeChange` and new `removePin`. |
| `func removePin(id: UUID)` | **NEW.** `visiblePins.removeAll { $0.id == id }`. See §8.2 for why DELETE can't reuse `mergeRealtimeChange`'s `CommunityPin`-typed signature. |
| `func disconnectRealtime()` / `func reconnectRealtime()` | **NEW.** Wired to the new `scenePhase` branches in `ContentView`. |
| `pinRefreshIntervalSeconds` | `8` → retuned per §6.1 (recommend 45–60s; not a hard requirement, tunable). |
| `setDriveModeActive(_:)` | **Unchanged logic** — still suspends the periodic poll during Drive Mode. What changes is *why* that's now safe: Realtime is expected to still be connected and pushing (§7), not that the suspension itself needed new code. |
| `init(...)` | Gains an injected `realtimeChannel: RealtimePinSubscribing` parameter (default: real `SupabasePinRealtimeChannel`, mirroring the existing `authService`/`urlSession` injectable pattern already in this initializer). |

**`SupabaseAuthService.swift` changes:** internals rewritten around the SDK's `AuthClient`; **every public
symbol keeps its exact current signature** (`currentUserId: UUID?`, `isAuthenticated: Bool`,
`validAccessToken() async -> String?`) — this is the literal claim already recorded in `HANDOFF.md`'s A3
note ("No API changes needed for the swap") and I'm holding the team to it. See §9.

**New file — `Services/SupabaseClients.swift`:** app-lifetime holder for the two SDK client instances
(`AuthClient`, `RealtimeClientV2`), constructed once in `WeParkApp.swift` and injected into
`SupabaseAuthService` + `CommunityPinService`, mirroring the existing "single instance created in
WeParkApp.swift and injected" convention already documented in `SupabaseAuthService.swift`'s header.

### 3.5 Tables / RPCs
None new. `public.pins` is already Realtime-enabled server-side (§2 Out). No RLS change — `pins_select_public`
already permits anonymous SELECT on non-`parked_car` pins, and Realtime respects the same RLS as REST
(Supabase's Realtime authorizes each subscribed row against the subscriber's RLS context).

---

## 4. Phase 0 — the Mac-gated SPM dependency add (read before anything else)

This is the step that sank the prior attempt. The prior engineer tried to add `supabase-swift` **without
Xcode**, because of the project's standing rule against Xcode's pbxproj autoformatting. That requires
hand-building `Package.resolved` with exact version checksums for the *entire* resolved dependency graph —
and `supabase-swift` is a multi-product package with several transitive dependencies (not the "one small
library" case), which makes hand-typing checksums correctly, from nothing, materially riskier than it might
sound. The engineer correctly stopped and fell back to raw `URLSession` rather than risk a broken
`xcodebuild`. That fallback is why the write path, the anon-auth, and Tier 3 reporting all work today on
raw `URLSession` — nothing was lost by stopping.

**This time, the difference is that a Mac with the real Xcode toolchain is available and this step is
explicitly scoped as its own isolated, verifiable unit of work** — not bundled into a larger feature PR the
way the prior attempt was.

### 4.1 Recommendation: Option A — one reviewed Xcode package-add, isolated commit

I'm recommending the Xcode-GUI path as primary, not the hand-pbxproj path, for one specific reason: **Option
A is the only path that produces guaranteed-correct `Package.resolved` checksums without a workaround.**
`xcodebuild -resolvePackageDependencies` (Option B, §4.3) still needs *something* to resolve against — a
pbxproj that already declares the package reference — and hand-typing that declaration correctly, for a
package this project has never linked before (zero existing `XCRemoteSwiftPackageReference` objects in
`project.pbxproj` today — confirmed via grep, this would be the *first* SPM dependency this project has
ever added), is exactly the kind of "get one field wrong, `xcodebuild` breaks entirely" risk the brief
warns about. The GUI path lets Xcode's own resolver do that work for real, once, under close supervision.

**Exact steps, in order, on Kevin's Mac:**

1. Confirm `git status` is clean on `main`. Cut a fresh branch: `git checkout -b build/add-supabase-swift-spm`.
2. Before opening Xcode: check the current latest tagged release at
   `https://github.com/supabase/supabase-swift/releases` (repo is `supabase/supabase-swift`, not
   `supabase-community/...` — that org moved). Note the version — you'll pin to it explicitly, not "any
   later version," so a future untested SDK bump doesn't silently land.
3. Open `WePark.xcodeproj` in Xcode.
4. Project navigator → select the **WePark project** (blue icon, top of the tree) → select target
   **WePark** (the app target, not the test target) → **Package Dependencies** tab → **+**.
5. Paste `https://github.com/supabase/supabase-swift`. Set the dependency rule to **"Exact Version"** (or
   "Up to Next Major Version" starting from the tag you noted in step 2 — either is fine; "Exact" is more
   conservative and matches this project's general preference for pinned, explicit values over floating
   ranges). Click **Add Package**.
6. **In the product-picker dialog that follows, check ONLY `Auth` and `Realtime`.** Leave `Supabase`
   (the umbrella), `PostgREST`, `Storage`, and `Functions` unchecked. Target: **WePark** only (not
   `WeParkTests` — tests reach the SDK-backed types through `@testable import WePark`, no direct product
   link needed on the test target). Click **Add Package** to confirm.
7. Wait for Xcode's resolve to finish (progress spinner in the top toolbar, or the status bar). This writes
   a new `Package.resolved` file (path is workspace-relative, typically
   `WePark.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` for a project without a
   separate `.xcworkspace` — confirm the actual path Xcode created via `git status`, don't assume).
8. **Quit Xcode immediately (⌘Q)** once the resolve finishes. Don't browse other files or tabs first — this
   project already has a "stale build number" gotcha from leaving Xcode open across other operations
   (`HANDOFF.md`, builds 8/12); the same "close it and reopen clean" discipline applies here to avoid any
   incidental unrelated edit riding along.
9. In Terminal: `git status`. **Expected: exactly two changes** — modified
   `ios/WePark/WePark.xcodeproj/project.pbxproj`, and one new `Package.resolved` file. If anything else
   changed (another target's settings, an unrelated file), stop and investigate before proceeding.
10. `git diff ios/WePark/WePark.xcodeproj/project.pbxproj | less`. **Expected: a purely additive diff** —
    one new `XCRemoteSwiftPackageReference` block, two new `XCSwiftPackageProductDependency` blocks (Auth,
    Realtime), the WePark target's `packageProductDependencies` array gaining two entries, the project's
    `packageReferences` array gaining one entry. **If the diff instead shows large stretches of unrelated
    existing lines reformatted or reordered — the autoformat hazard this project's standing rule exists to
    avoid — STOP. Do not commit.** Run `git checkout -- ios/WePark/WePark.xcodeproj/project.pbxproj` to
    revert, delete the stray `Package.resolved`, and fall back to Option B (§4.3).
11. Verify it actually builds, before any Swift code depends on it:
    `xcodebuild clean build -project ios/WePark/WePark.xcodeproj -scheme WePark -configuration Debug -destination 'generic/platform=iOS Simulator'`.
    **Expected: `** BUILD SUCCEEDED **`.** (If it fails specifically citing a Swift language-version /
    tools-version mismatch: `supabase-swift` requires Swift tools 6.1+ to build the package itself, which
    Xcode 26.4.1 supports; this is a resolvable version-pin issue, not evidence the approach is wrong —
    try pinning to an earlier `supabase-swift` tag if the newest one has a stricter minimum than the
    toolchain provides.)
12. Commit **only** this diff, isolated from any other change:
    `git add ios/WePark/WePark.xcodeproj/project.pbxproj <the Package.resolved path>`, commit message
    `build: add supabase-swift SPM dependency (Auth + Realtime products, v<X.Y.Z>)`. Push the branch.
13. Report back (to whichever session picks up Streams A/B): the exact pinned version, confirmation of
    `BUILD SUCCEEDED`, and the commit SHA. **This is the unblock signal — nothing in Streams A or B starts
    before this exists on `main`.**

### 4.2 Verification checkpoint before any Swift code depends on it
Steps 9–11 above **are** the checkpoint. Do not skip 10 (diff review) or 11 (clean build) even though they
feel redundant with each other — 10 catches "the pbxproj diff is unreviewable," 11 catches "the diff looked
fine but doesn't actually link." Both have failed independently in this project's history on unrelated
build-setting changes (`HANDOFF.md`, W8.5a's `INFOPLIST_KEY_` gotcha — a diff that looked correct but didn't
behave correctly at runtime).

### 4.3 Fallback — Option B, only if Option A's diff (step 10) is unreviewable

1. On the Mac, create a **throwaway scratch Xcode project** somewhere outside this repo (e.g.
   `~/Desktop/scratch-spm-harvest`), any template.
2. Repeat §4.1 steps 3–7 against the **scratch** project only, pinned to the same version.
3. Inspect the scratch project's `project.pbxproj` diff and generated `Package.resolved` — this is now a
   real, Xcode-verified template of the exact object shapes (repo URL, resolved revision, checksums,
   product-dependency object IDs) for that specific pinned version, harvested from a real resolver run
   rather than typed from memory or guessed.
4. Hand-copy the equivalent structural diff into the **real** `project.pbxproj` (fresh 24-hex-character
   object IDs generated per Xcode's own convention, swapped in) using a plain text editor — never opening
   the real project in Xcode's GUI project editor. This can be done from the VPS session since it's now
   copying a *verified* template, not inventing one.
5. Hand-copy the scratch-harvested `Package.resolved` content into the real project's expected path — the
   package/version/checksums are identical regardless of which project references them, so this part is a
   straight copy, not a re-derivation.
6. On the Mac, run `xcodebuild -resolvePackageDependencies -project ios/WePark/WePark.xcodeproj -scheme WePark`
   (CLI only, no GUI) — this has Xcode's real resolver validate the hand-placed `Package.resolved` against
   the hand-edited pbxproj references. If anything doesn't line up, **this command fails loudly here**,
   before any build attempt — which is the whole point of running it as a distinct, cheap-to-retry step.
7. Then §4.1 steps 9–13 (diff review is now trivially expected to pass since the diff *is* the hand-copy;
   the real gate here was step 6), clean build, isolated commit.

Option B costs materially more engineering time than Option A (a scratch-project detour plus careful manual
transcription) and is not free of its own risk (transcription error) — it exists as a real, usable Plan B,
not a recommendation.

---

## 5. Realtime subscription design

### 5.1 Which table/filter, and why there's exactly one channel (not three)

The existing `startRealtime()` TODO comment (lines 318–321, written at Tier 1) sketches **two channels**
mirroring the two REST fetch channels (`source=eq.open_data`, `lifespan=eq.ephemeral`). **This is the wrong
design and I'm not implementing it as written** — flagging this explicitly per §14 because it's the literal
existing guidance in the code and a naive implementation would follow it.

Supabase Realtime's `postgres_changes` filters support single-column comparisons (`eq`, `in`, etc.) but
**not compound multi-column predicates** — you cannot express "`source = 'crowd' AND lifespan = 'ephemeral'
AND resolved_at IS NULL AND (expires_at IS NULL OR expires_at > now())`" as a subscription filter the way
the REST layer's `URLQueryItem` list already does. Splitting into "channel 1 = one `eq` filter, channel 2 =
another `eq` filter" doesn't actually reproduce the REST channels' real predicates; it just picks one column
each and silently drops the rest, which would (for example) push resolved or already-expired pins straight
into `visiblePins`.

**Design: one subscription, table-wide, on `public.pins`, `event: *` (insert/update/delete).** All filtering
— pin-type eligibility, expiry, resolved-at, and now viewport (§8.2) — happens **client-side**, reusing the
existing `clientSideFilter` for expiry/resolved-at and the new `RealtimeMergeGate` for type/viewport. This
also means FT-15's new pin types (`filming`/`construction` with `report_group_id`) get Realtime coverage
automatically once added to `RealtimeMergeGate.mergeablePinTypes` — no second subscription, no second
Realtime-adoption pass (§8.3).

### 5.2 Reconnect and backoff
Not hand-rolled. `RealtimeClientV2` (the SDK's current architecture) manages WebSocket reconnect with
backoff internally. This spec's responsibility is limited to reacting to its connection-status signal:
- `RealtimePinSubscribing.isConnected` (or the SDK's own status stream, wrapped by
  `SupabasePinRealtimeChannel`) is exposed so `CommunityPinService` can, in principle, tighten the fallback
  poll cadence while disconnected — **not required for phase 1** (see §12 phasing), noted as a natural
  follow-up once the basic connect/merge path is proven.

### 5.3 App foreground/background transitions
New `handleScenePhaseChange` branches in `ContentView.swift` (currently only handles `.active`, lines
2101–2118):
- `.background` → `pinService.disconnectRealtime()`. iOS suspends/kills background socket activity for an
  app with no background-execution entitlement anyway; disconnecting explicitly avoids the socket dying in
  an ambiguous half-open state.
- `.active` (existing branch, extended) → `pinService.reconnectRealtime()` **plus** one immediate
  `fetchPins(for: lastFetchedRegion)` REST call — a catch-up reconciliation for whatever happened while
  backgrounded, belt-and-suspenders alongside the reconnect.

### 5.4 What happens on a dropped socket
Two layers, deliberately:
1. **The SDK's own reconnect** (§5.2) — invisible to this app's code, handles transient network blips.
2. **The retuned periodic REST poll** (§6.1) stays as a reconciliation fallback whenever the app is
   foregrounded and Drive Mode is not active. If the socket is down for an extended period (e.g. a
   Supabase-side outage), the poll — at its new, longer interval — is still there catching up the visible
   region every cycle. **Polling is not dead weight; it's demoted from primary to backstop.**

The one case with **no** fallback by design is **Drive Mode with a dropped socket** — see §7's honest
statement of that tradeoff.

---

## 6. Migration path from raw URLSession, and what stays

### 6.1 REST fetch/write channels — unchanged, kept as raw URLSession

`buildOpenDataRequest`, `buildCrowdEphemeralRequest`, `fetchPins`, `insertCrowdPin`, `upsertVote`,
`callExtendPinExpiry`, `decodeResponse` — **none of these change.** This is a deliberate scope cut (§2 Out,
§14): the brief's ask is specifically Realtime + Keychain, and migrating the REST layer to the SDK's
`PostgREST` client buys nothing toward that goal while adding a third linked SDK product, a larger
transitive dependency surface in Phase 0, and a rewrite of code that works today and has no reported bugs.

**Periodic poll retuning:** `pinRefreshIntervalSeconds` moves from 8s to a longer interval — recommend
**45–60s** — now that it's a reconciliation backstop rather than the primary freshness mechanism. Not a hard
number; tune post-launch same as every other named constant in this codebase.

### 6.2 What gets deleted
Nothing gets deleted outright. `startRealtime()`'s body is replaced (from no-op to real subscription); the
periodic-refresh machinery stays, just retuned. The only literal deletion is the stale TODO comment at
lines 318–321 describing the two-channel design this spec explicitly rejects (§5.1) — replaced with the
real one-channel design.

### 6.3 FT-15's third fetch channel — coordination, not collision

FT-15's Stream B4 (`docs/ft15-tf215-temporary-block-restrictions-spec.md` §10) adds
`buildCrowdBlockScopedRequest` — a **third REST channel** — to this same `CommunityPinService.swift`, plus
widens `mergeableTypes`-equivalent logic and the merge/consumption surfaces. That work is independent of
this spec's Realtime subscription in principle (REST channel count vs. Realtime channel design are
orthogonal), but they're **large, concurrent diffs on the same file**, and FT-15 is further along (three
open PRs as of this spec's writing).

**Recommendation: sequence, don't parallelize, on this one file.** This spec's Stream B should not start
until FT-15's `CommunityPinService.swift` changes (its Streams B3 and B4) are merged to `main`. See §11 for
the concrete ordering. This does mean Realtime doesn't land as fast as it theoretically could in a vacuum —
flagging as OQ-2 (§13) since it's a real schedule tradeoff Kevin should see stated plainly, not buried in a
work-stream table.

---

## 7. The Drive Mode gap — the headline win, stated honestly

**Today:** `setDriveModeActive(true)` suspends the periodic poll entirely (`CommunityPinService.swift:254-265`).
Community pins go **completely stale** for the duration of Drive Mode / Find Parking — exactly the moment
Kevin's own framing says freshness matters most: *"you most want fresh enforcement pins while circling"*
(`HANDOFF.md`, 2026-06-06 A3 note).

**After this spec:** the Realtime socket **stays open and connected through Drive Mode.** The periodic REST
poll stays suspended during Drive Mode (unchanged from today) — but that's now fine, because Realtime is the
live mechanism, not the poll. A pin reported by another user two blocks away while you're circling now
appears on your map in ~1–3s whether or not you're driving, which is the entire point of this feature.

**The honest battery tradeoff:** holding a WebSocket connection open for the duration of a Drive Mode
session is additional radio/CPU activity beyond what Drive Mode already spends on continuous GPS,
screen-on, and speech synthesis. I don't have a number to give here — that's precisely why §10 exists as
its own section rather than an assumption. My own expectation, stated as a hypothesis to be measured, not a
claim: an idle-but-connected WebSocket (occasional small keepalive frames, occasional small event payloads)
is a *marginal* addition on top of what continuous GPS + screen-on + TTS already cost during Drive Mode —
but "marginal" is exactly the kind of claim that needs a real measurement before it's trusted, given this
feature's own history (periodic polling was suspended during Drive Mode for battery reasons *without* a
documented measurement backing that decision either — see §14).

**What I'm explicitly NOT recommending:** suspending Realtime during Drive Mode the same way the poll is
suspended. That would just reproduce today's exact gap under a different mechanism name. If §10's
measurement comes back showing a real, unacceptable battery cost, the fallback is a *coarser* Drive-Mode
behavior (e.g., disconnect/reconnect on a slow cycle rather than holding the socket open continuously) —
not "suspend it entirely again," which defeats the feature.

---

## 8. Merge-path additions (the two real gaps the "few hours" estimate missed)

### 8.1 The merge core is already correct — don't re-plan it
`mergeRealtimeChange(pin:)` (lines 578–608) already does the right thing for INSERT/UPDATE: append if new,
replace if existing, remove if `resolvedAt` is now set, apply `clientSideFilter` for expiry. 8 tests already
cover this (`CommunityPinServiceTests.swift`, `testMergeRealtimeChange_*`). **This spec adds a gate in front
of it and one new function beside it — it does not modify the function itself.**

### 8.2 Two gaps a naive "just subscribe and call mergeRealtimeChange" implementation would introduce

1. **No viewport gate.** Because a single table-wide subscription (§5.1) receives every change to
   `public.pins` city-wide — Realtime has no bounding-box filter — a naive wire-through would start adding
   every INSERT/UPDATE anywhere in NYC into `visiblePins`, not just the visible region. At current pin
   volumes (a handful of Tier 1/3 pins) this wouldn't visibly misbehave today, but it's a real, silent
   correctness gap that gets worse as usage grows, and MapKit's own annotation culling only hides it
   visually — the annotations still exist in memory and can pop into view on a pan without a fresh fetch.
   **Fix:** `RealtimeMergeGate.isWithinRegion` (§3.4) gates every event against `lastFetchedRegion` before
   it reaches `mergeRealtimeChange`.
2. **No DELETE handling at all.** `mergeRealtimeChange(pin: CommunityPin)` requires a fully-decoded
   `CommunityPin` — many fields `NOT NULL` (pin_type, source, lat, lng, etc.). A Postgres Realtime DELETE
   payload, without `REPLICA IDENTITY FULL` set (not set today, and this spec doesn't propose changing it —
   §2 Out), only reliably carries the row's primary key. Author-initiated pin deletion isn't built yet
   (`HANDOFF.md` backlog: "FT-2 delete-own-pin — SPEC'D, NOT built") — but Kevin's own manual SQL cleanup
   already deletes rows directly in prod (the "delete the 2 forever-test pins" instruction appears **three
   separate times** in `HANDOFF.md`'s changelog). Any manual `DELETE FROM public.pins` while a client is
   subscribed fires a Realtime DELETE event today with nothing listening for it, and would crash-or-silently-fail
   if routed through the existing `CommunityPin`-typed merge signature. **Fix:** new `removePin(id: UUID)`
   (§3.4), by primary key only, no schema change required.

### 8.3 FT-15 pin types slot in without a second adoption pass

Because the subscription is table-wide (§5.1) and eligibility is gated by
`RealtimeMergeGate.mergeablePinTypes` (a named `Set<PinType>` constant, not scattered inline logic), adding
FT-15's `filming`/`construction` block-scoped types to Realtime coverage later is a one-line addition to that
set — not a second subscription, not a second design pass. I'm calling this out explicitly so it's
understood as a designed-in seam, not an accident.

---

## 9. Keychain session storage + auto-resign on `.signedOut`

`SupabaseAuthService`'s internals get rewritten around the SDK's `AuthClient`:
- **Session storage:** the SDK's `Auth` product defaults to Keychain-backed local storage on Apple
  platforms (no custom storage injection needed to get this) — replacing the current hand-rolled
  `UserDefaults` persistence (`Keys.accessToken`/`refreshToken`/`userId`/`expiresAt`, lines 83–88). This is
  the QA nit already on record (`SupabaseAuthService.swift` header comment: *"A fast-follow PR should
  migrate to Keychain when the SDK is added"*).
- **Auto-resign on `.signedOut`:** the SDK's `AuthClient` publishes an auth-state-change event stream that
  includes a `.signedOut` case (token revoked, or an explicit sign-out). WePark's identity model is "silent
  anonymous session, always logged in, never a user-visible logged-out state" (`docs/tier3-auth-and-reactions-spec.md`
  §3.8) — so on `.signedOut`, the wrapped service re-triggers `signInAnonymously()` automatically, rather
  than only checking lazily at the next write's `validAccessToken()` call the way `ensureSession()` does
  today. This closes a real (if narrow) gap: today, if a session is externally revoked between app launches,
  nothing notices until the next write attempt fails.
- **Public API: byte-identical.** `currentUserId: UUID?`, `isAuthenticated: Bool`,
  `func validAccessToken() async -> String?` keep their exact current signatures. Every caller —
  `CommunityPinService.insertCrowdPin`/`upsertVote`/`callExtendPinExpiry` — needs **zero changes**. This is
  the literal claim already on record in `HANDOFF.md`'s A3 note and this spec holds engineering to it as an
  acceptance criterion (§12), not just an aspiration.
- **Existing `SupabaseAuthServiceTests`** (URLProtocol-mocked against raw `URLSession`) get replaced with
  tests against the SDK-backed internals. This is real work, not a formality — the SDK's `AuthClient` isn't
  mockable via the same `URLProtocol` injection pattern; the seam needs to move up a level (inject a
  test-double `AuthClient`-shaped protocol, or use the SDK's own test utilities if it ships any — verify
  what's available once Phase 0 lands and the SDK's actual API surface is inspectable).

---

## 10. Battery / data measurement — how we'd know this didn't regress

This is the section the original "poll suspended during Drive Mode" decision never got, and it's the honest
answer to why §7's tradeoff is stated as a hypothesis rather than a claim.

**Cheapest, already-available mechanism:** this app is TestFlight-distributed. Xcode Organizer's **Energy
Log** / battery-metrics report aggregates real on-device usage from TestFlight builds automatically — no
new code required to collect it. Once a build with this feature ships:
1. Compare the Organizer energy report for the pre-Realtime build (poll-based) against the post-Realtime
   build, focused on sessions with Drive Mode active. This needs real usage accumulated over days, not an
   instant read — flag that as a real limiting factor given Kevin field-tests largely solo.
2. **Faster, practical proxy Kevin can run himself:** a manual controlled A/B — note the iPhone's battery
   percentage (Settings → Battery, or the status-bar percentage) before and after two comparable ~20–30 min
   Drive Mode sessions, one on a pre-Realtime build, one on a post-Realtime build, same route/conditions as
   close as practical. Crude, but immediate and doesn't require waiting on aggregate TestFlight telemetry.
3. **Data usage:** Settings → Cellular → per-app data, before/after a comparable session, as a secondary
   signal (a WebSocket held open is a bounded, low-frequency stream — expected to be small relative to
   Mapbox tile/route fetches already happening during Drive Mode, but should be checked, not assumed).

**What this spec does NOT propose:** custom in-app battery instrumentation (e.g., `UIDevice.batteryLevel`
sampling + a debug HUD). That's real, buildable work but disproportionate to this feature's size — the
Organizer + manual-A/B combination is the pragmatic first pass; escalate only if the manual check surfaces
something concerning.

---

## 11. Work Streams

| Stream | Owner | Files | Depends on | Parallel? |
|---|---|---|---|---|
| **P0 — SPM dependency add** | **Kevin, Mac** | `ios/WePark/WePark.xcodeproj/project.pbxproj`, new `Package.resolved` | This spec approved | **No dependency on anything else** — has zero file overlap with FT-15 or any in-flight iOS work. Can run at literally any time, including right now, in parallel with FT-15's remaining streams. |
| **A — Auth/Keychain refactor** | `@ios-engineer` | `Services/SupabaseAuthService.swift`, `Services/SupabaseClients.swift` (new), `WeParkApp.swift`, `WeParkTests/SupabaseAuthServiceTests.swift` | P0 | Yes — no file overlap with FT-15's streams (A/B1–B4) or with this spec's own Stream B. Can start the moment P0 lands, run fully in parallel with FT-15's remaining work. |
| **B — Realtime channel + `CommunityPinService` wiring** | `@ios-engineer` | `Services/CommunityPinService.swift`, `Services/RealtimePinChannel.swift` (new), `Services/RealtimeMergeGate.swift` (new), `ContentView.swift` (one `scenePhase` branch — no camera/overlay surface), `WeParkTests/CommunityPinServiceTests.swift` | P0 **and** FT-15's Streams B3+B4 merged to `main` (§6.3, §13 OQ-2) | **Sequenced, not parallel, with FT-15 on this one file.** Can otherwise run in parallel with Stream A (different files entirely). |
| **C — Battery/data measurement** | Kevin, real device | n/a (§10) | A + B merged, in a shipped build | Post-merge, needs real usage accumulation — not blocking merge itself, but should gate any claim that this "fixed" the Drive Mode gap without regressing battery. |
| **QA** | `@qa-verifier` | reads the diff cold across A + B | A + B merged | Serial, per `.claude/TEAM.md` invariant. Realtime's actual event-delivery behavior IS live-verifiable in the Simulator (unlike GPS/heading work) — two simulators, or one sim + a direct SQL insert against prod, reproduces the "does an insert from elsewhere appear in ~1-3s" check without needing Kevin's physical device (§9 test strategy detail). |

**Parallel group 1 (start immediately, no ordering constraint):** P0.
**Parallel group 2 (after P0):** Stream A. Stream B waits on FT-15's file settling (below).
**Serial checkpoint:** Stream B does not open a worktree until FT-15's `CommunityPinService.swift` changes
(Streams B3, B4 per `docs/ft15-tf215-temporary-block-restrictions-spec.md` §10) are on `main`. At that
point Stream B branches from current `main` (already containing FT-15's changes) rather than trying to
merge two large concurrent diffs on the same file.

---

## 12. Phasing and sizing — why "a few hours" is wrong

`HANDOFF.md`'s standing estimate (2026-06-06, A3 note): *"Estimate for the full SDK fix: ~few hours + some
SPM detour risk."* **I don't think that's real, and I'm not going to repeat it.** Independent breakdown:

- **P0 (Mac):** not "a few hours" in isolation, but genuinely small — call it 0.5–1.5 hours of Kevin's
  hands-on time for the happy path (§4.1 steps 1–13), with real (not hypothetical) schedule risk if the
  diff review at step 10 fails and Option B (§4.3) is needed instead.
- **Stream A (Auth/Keychain):** not a drop-in swap. The internals change from a hand-rolled, fully
  URLProtocol-mockable request/response flow to a real SDK client whose test seam has to be rebuilt from a
  different angle (§9). Realistically **~1 session.**
- **Stream B (Realtime wiring):** this is the actual meat of the feature, and it's not "wire a callback into
  an existing function" — it's a new subscription abstraction (for testability), a new pure viewport-gate
  function, a new DELETE-handling path that doesn't exist today, new scenePhase lifecycle wiring, and a
  poll-interval retune, each needing its own tests on top of the 8 that already exist for the merge core.
  Realistically **~1.5–2 sessions**, not counting the sequencing wait on FT-15.
- **Sequencing cost (§6.3, §11):** Stream B is explicitly gated behind FT-15's own multi-session iOS work
  landing first — a real calendar dependency, not engineering effort, but it affects when this can actually
  ship regardless of how fast the coding itself goes.
- **QA:** one pass minimum, likely two given this touches auth internals and a new async event-delivery
  path — realistically not shorter than FT-15's own QA cadence.
- **Measurement (§10):** not blocking merge, but real elapsed-time cost before anyone can honestly say
  "this didn't regress battery" — days, not hours, if leaning on Organizer telemetry; faster if Kevin runs
  the manual A/B himself.

**My own number: P0 (small, Mac-side) + roughly 2.5–3.5 iOS engineering sessions (Streams A + B combined) +
1–2 QA passes** — in the same rough class as FT-15's own iOS estimate (4–6 sessions), not a quick add-on
squeezed in alongside it. If a shorter timeline was implied anywhere, it isn't real; recommend scheduling
this as its own tracked item behind FT-15's in-flight iOS streams, not as a quick parallel side-task.

### Phase order
1. **Phase 0** — Mac SPM add (§4). Blocking, but small and independently schedulable.
2. **Phase 1** — Stream A (Auth/Keychain), fully parallel with FT-15's remaining work.
3. **Phase 2** — Stream B (Realtime wiring), starts once FT-15's `CommunityPinService.swift` changes are on
   `main`.
4. **Phase 3** — QA, ship.
5. **Phase 4** — Battery/data measurement (§10), ongoing post-ship, informs whether Drive Mode's
   keep-socket-open behavior needs the coarser fallback noted in §7.

---

## 13. Open Questions (Kevin)

**OQ-1 (non-blocking).** Poll interval retune from 8s to 45–60s (§6.1) — a first-pass number, not measured.
Fine to ship and tune; flagging so it's understood as a placeholder.

**OQ-2 (🔴 the one I'd actually want a yes/no on).** Sequencing Stream B behind FT-15's
`CommunityPinService.swift` changes (§6.3, §11) is a real schedule cost, not free. The alternative — running
both concurrently and accepting a merge-conflict-resolution session at the end — is faster in the optimistic
case but risks a much messier reconciliation if both land large diffs to the same file independently.
**I'm recommending sequenced.** If Kevin wants Realtime landed faster regardless of the FT-15 collision risk,
say so and I'll re-cut this as a smaller "just the subscription, minimal `CommunityPinService.swift` touch"
first slice that's easier to rebase around FT-15 rather than a full simultaneous rewrite.

**OQ-3 (non-blocking).** §4.1 recommends "Exact Version" pinning for the SPM dependency rule. Fine to use
"Up to Next Major" instead if Kevin would rather get patch/minor updates automatically — my lean toward
exact-pin is just this project's general preference for pinned values over floating ranges (matches the
`Config.xcconfig`/named-constant conventions already established), not a strong opinion either way.

**OQ-4 (non-blocking).** Should `RealtimePinSubscribing.isConnected` actually drive a tightened fallback-poll
cadence while disconnected (§5.2), or is that over-engineering for phase 1? I left it as "exposed but unused"
in phase 1 — cheap to wire up later if the reconnect-gap case turns out to matter in practice.

---

## 14. Things I'm flagging as risks, not rubber-stamping

**The existing `startRealtime()` TODO comment describes the wrong design, and a literal implementation of
it would ship a real bug.** §5.1 and §8.2 cover this in detail: splitting into "two channels, one `eq`
filter each" silently drops the compound predicates (`resolved_at is null`, expiry) the REST channels
actually enforce, and neither variant of that TODO mentions a viewport gate or DELETE handling at all. I'm
calling this out explicitly because it's sitting in the codebase today as apparent guidance, and whoever
picks up Stream B should not follow it as written.

**Don't migrate the REST layer to the SDK's `PostgREST` client "since we're already adding the SDK."** This
is the single most likely scope-creep temptation on this feature, and I'm recommending against it
unilaterally (§2 Out, §6.1). The REST read/write paths work today, have real test coverage via
`URLProtocol` mocking that would need to be entirely rebuilt against a different seam if migrated, and
migrating them buys nothing toward this feature's actual goal (Realtime + Keychain). If a future spec wants
to standardize on the SDK for REST too, that's a separate, smaller, well-scoped follow-up — not something to
fold in here because the dependency happens to already be linked.

**The Drive Mode battery tradeoff (§7, §10) is genuinely unmeasured, on both sides.** Neither today's
"suspend polling during Drive Mode for battery" decision nor this spec's "keep Realtime open through Drive
Mode instead" have a real number behind them yet. I'm not blocking on getting that number before shipping
(§10's measurement plan is explicitly post-merge, Phase 4) because the product case for the fix is strong
enough that Kevin should get the feature and then verify — but I want it on record that "keep the socket
open" is a reasoned bet, not a verified-safe change, at ship time.

**A single table-wide Realtime subscription with no server-side filter is the right call at today's pin
volume, but it's a scaling watch-item, not a permanently-correct design.** At tens of pins citywide, the
client-side viewport gate (§8.2) fully absorbs the cost of receiving every change everywhere. If pin volume
grows by an order of magnitude or more (real community density — the whole point of this feature working),
the "receive everything, filter client-side" approach starts spending real bandwidth/battery on events that
never get merged. Not a reason to delay this spec; a reason to revisit the subscription design once density
actually shows up as a problem, not before.

**I did not spec a mechanism for verifying the Keychain migration actually preserves an existing user's
session across the app update** (i.e., someone with a `UserDefaults`-persisted anon session today, updating
to this build — does their identity/reputation carry over, or do they silently get a fresh anonymous
identity?). Given the current user base is effectively Kevin plus a small number of field testers, I don't
think this needs a formal migration path (a fresh anon identity on update is a low-cost outcome right now),
but flagging it explicitly rather than letting it pass unaddressed — `@ios-engineer` should decide in Stream
A whether a one-time "read the old `UserDefaults` keys if the new Keychain store is empty" migration shim is
worth the ~10 lines it'd cost, given how cheap it is relative to the alternative of silently discarding
existing anon identities.

---

## 15. Acceptance Criteria

**Phase 0 (Kevin, Mac):**
- [ ] **AC-P0-1.** `git diff` on `project.pbxproj` after the package add is purely additive (§4.1 step 10)
      — no unrelated build-setting reordering.
- [ ] **AC-P0-2.** Only `Auth` and `Realtime` products are linked to the `WePark` target — verified by
      inspecting the target's `packageProductDependencies` in the diff (no `Supabase`, `PostgREST`,
      `Storage`, `Functions`).
- [ ] **AC-P0-3.** `xcodebuild clean build` succeeds against the resolved dependency (§4.1 step 11).
- [ ] **AC-P0-4.** The SPM-add commit contains *only* `project.pbxproj` + `Package.resolved` — no other
      file changed alongside it.

**Stream A — Auth/Keychain:**
- [ ] **AC-A1.** `SupabaseAuthService`'s public API (`currentUserId`, `isAuthenticated`,
      `validAccessToken() async -> String?`) is byte-identical to pre-spec — zero call-site changes required
      in `CommunityPinService.swift`'s write methods.
- [ ] **AC-A2.** A fresh anonymous session, once established, is retrievable from Keychain (not
      `UserDefaults`) — verified by inspecting the actual storage backend used, not just by behavior.
- [ ] **AC-A3.** A `.signedOut` event from the SDK's auth-state stream triggers an automatic re-sign-in,
      verified by a test that simulates the event and asserts `signInAnonymously()`-equivalent behavior
      fires without any caller action.
- [ ] **AC-A4.** No `Calendar.current` usage introduced (existing project-wide invariant).
- [ ] **AC-A5.** `SupabaseAuthServiceTests` pass against the new internals; the previous `UserDefaults`-key
      constants (`Keys.accessToken` etc.) are either removed or clearly marked legacy/migration-only.

**Stream B — Realtime:**
- [ ] **AC-R1.** `startRealtime()` establishes a real subscription on `public.pins` (verified live per the
      QA note in §11 — two simulators or one sim + a direct prod SQL insert, not just unit-test mocking).
- [ ] **AC-R2.** `RealtimeMergeGate.isWithinRegion` correctly includes a pin inside the padded viewport and
      excludes one clearly outside it (unit-testable, no socket needed).
- [ ] **AC-R3.** An INSERT event for an eligible, in-viewport pin type reaches `mergeRealtimeChange` and
      appears in `visiblePins` — existing 8 merge tests unmodified and still passing, plus new tests
      covering the gate in front of them.
- [ ] **AC-R4.** An event for a pin type not in `RealtimeMergeGate.mergeablePinTypes`, or outside the
      viewport, is dropped before reaching `mergeRealtimeChange` (does not appear in `visiblePins`).
- [ ] **AC-R5.** A DELETE event removes the corresponding pin from `visiblePins` by ID via `removePin(id:)`,
      without requiring a fully-decoded `CommunityPin`.
- [ ] **AC-R6.** `disconnectRealtime()` / `reconnectRealtime()` are wired to the new `.background`/`.active`
      `scenePhase` branches in `ContentView.swift`, with zero change to the existing `.active`-branch logic
      (banner refresh, mute re-sync, reminder re-sync, stale-target guard, deep-link replay all unmodified).
- [ ] **AC-R7.** `setDriveModeActive(true)` leaves the Realtime subscription connected while still
      suspending the periodic poll (unchanged suspension logic, new "why it's safe" per §7).
- [ ] **AC-R8.** `pinRefreshIntervalSeconds` is retuned per §6.1's recommendation (or Kevin's chosen value)
      and is still a named, tunable constant.
- [ ] **AC-R9.** No new camera/overlay mutation surface introduced — `ContentView.swift`'s diff is confined
      to the `scenePhase` branch and service wiring; `MapViewRepresentable.swift` has zero diff.
- [ ] **AC-R10.** Full test suite green; `@ios-engineer` reports the exact before/after count in the PR.
- [ ] **AC-R11.** `RegionSyncGuardTests` pass unmodified (standard #31-class regression gate, even though
      this feature doesn't touch camera code — cheap to verify, costly to skip).

**Coordination:**
- [ ] **AC-C1.** Stream B's branch is cut from a `main` that already contains FT-15's `CommunityPinService.swift`
      changes (Streams B3+B4) — verified by checking the branch point, not just "it compiled."

**Measurement (Phase 4, post-merge):**
- [ ] **AC-M1.** At least one manual A/B battery-percentage comparison (§10 item 2) is recorded, comparing a
      pre-Realtime and post-Realtime build over comparable Drive Mode sessions.
- [ ] **AC-M2.** Cellular data usage for a comparable session is checked and is not surprising relative to
      the same session's Mapbox tile/route data usage (§10 item 3) — not a hard numeric bar, a sanity check.

---

## 16. Out-of-Scope Follow-Ups

**REST layer migration to the SDK's `PostgREST` client.** Deliberately not built here (§2, §6.1, §14).
Revisit only as its own scoped follow-up if there's a concrete reason to standardize (e.g., the SDK's
typed query builder meaningfully reduces a real maintenance burden the raw `URLQueryItem` approach has
started to show) — not "because the dependency is already linked."

**Connection-status-driven fallback-poll cadence** (OQ-4, §13). `RealtimePinSubscribing.isConnected` is
exposed but not acted on in phase 1. Cheap follow-up if reconnect-gap staleness turns out to matter in
practice.

**Keychain migration shim for pre-existing `UserDefaults`-persisted sessions** (§14's last risk item).
Explicitly punted given the current tiny user base; revisit if this ships to a meaningfully larger anon
user base before the shim exists.

**Custom in-app battery instrumentation** (§10). Organizer + manual A/B is the phase-1 measurement plan;
escalate to real instrumentation only if that first pass surfaces a concerning signal.

**Subscription-design revisit at scale** (§14's scaling-watch-item risk). Not needed at today's pin volume;
revisit once real community density exists — which is, not incidentally, the same "no value until density
exists" reasoning that originally deferred this whole feature from TF1.

---

## 17. Related Specs and Docs

- `HANDOFF.md` — "A3 SDK DEFERRED" entry (2026-06-05) — the prior attempt's failure mode this spec's §4
  directly responds to. "🔴 SDK = HARD TF2 REQUIREMENT" entry (2026-06-06) — Kevin's original framing and
  the "~few hours" estimate this spec's §12 revises.
- `docs/ft15-tf215-temporary-block-restrictions-spec.md` — the concurrent feature sharing
  `CommunityPinService.swift`; §11/§6.3/§13 OQ-2 above are the coordination plan.
- `docs/typed-pin-schema-spec.md` §12 (networking conventions), `supabase/02-pins-schema.sql` (RLS +
  Realtime publication — lines 288–296 confirm `public.pins` is already Realtime-enabled server-side).
- `docs/tier3-auth-and-reactions-spec.md` §3.8 — the anonymous-identity model this spec's Auth refactor
  preserves unchanged.
- `ios/WePark/WePark/Services/RouteService.swift:47-58` — the `RouteServicing` protocol-extraction
  precedent this spec's `RealtimePinSubscribing` mirrors for testability.
- `ios/WePark/WeParkTests/CommunityPinServiceTests.swift` — the 8 existing `mergeRealtimeChange` tests this
  spec builds on top of without modifying.
