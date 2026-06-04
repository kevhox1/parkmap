# Tier 3 Sub-PR #1 — Anonymous Auth + Write Path + Reactions UI

**Status:** Ready for dispatch after Kevin approves OQ table in `docs/tier3-patrol-mode-buildplan.md`. Date: 2026-06-04.
**Owner:** @ios-engineer (implementation). @tech-lead (this spec). @qa-verifier (acceptance).
**W8.5 slot:** W8.5e.
**Unblocks:** sub-PR #2 (patrol mode UI, W8.5f) + sub-PR #3 (decay display, W8.5g) — both can run in parallel once this PR merges.
**Anchor docs:**
- `docs/tier3-patrol-mode-buildplan.md` — overall Tier 3 sequence and OQ table.
- `docs/community-1.0-direction.md §6.3` — identity model decision (anonymous auth, no signup wall).
- `docs/community-1.0-direction.md §6.1` — reactions = trust engine (one-tap confirm extends/kills TTL).
- `docs/typed-pin-schema-spec.md §5–§6` — RLS policies the auth JWT satisfies.
- `supabase/02-pins-schema.sql` — LIVE in production: `pins_insert_crowd`, `votes_insert_own`, `extend_pin_expiry` RPC all already exist.
- `docs/tier1-pin-display-spec.md §5` — architectural invariants this spec must not break.

---

## Open Questions for Kevin — Resolve Before Engineering Starts

| # | Question | Options | Recommendation |
|---|---|---|---|
| OQ-1 | **React-to-your-own-pin guard: app layer or DB layer?** | (a) iOS-side only: `CommunityPinService` compares `pin.authorId == authService.currentUserId` before enabling the reaction UI. (b) DB-side: add a check constraint or RLS condition `auth.uid() != author_id` on votes insert. | **(a) iOS-side guard only, for now.** Adding an RLS condition on votes insert would require altering the live `votes_insert_own` policy — a DDL change in production that requires a new migration + QA. The iOS guard is sufficient for TF1/TF2 where Kevin controls the user population. A DB-layer guard can be added later if abuse warrants it. |
| OQ-2 | **"Gone" dispute threshold: how many disputes kill a pin?** | (a) `dispute_count >= 3` → auto-resolve (set `resolved_at` server-side). (b) `dispute_count >= 2 × confirm_count` (relative threshold). (c) Manual-only for TF1; let Kevin review disputed pins. | **(a) 3 disputes = auto-resolve**, executed by a DB trigger or RPC called from the iOS client. Rationale: the beachhead is SOHO/LES with a small, known user population; 3 disputes is a high relative bar in a thin crowd. The absolute threshold prevents a single bad actor from nuking a pin. Option (b) is better long-term (prevents gaming in a dense crowd) but requires more state and is over-engineered for TF1. Wire the DB trigger in this sub-PR per §3.3. |
| OQ-3 | **Supabase Swift SDK: adopt in sub-PR #1 or stay raw URLSession?** | (a) Add `supabase-swift` (v2.x) as an SPM dependency in sub-PR #1 — it handles anonymous auth, JWT refresh, realtime channel management, and RPC calls cleanly. (b) Continue raw URLSession + manual JWT management for TF1; defer SDK adoption to a future refactor. | **(a) Adopt `supabase-swift` in sub-PR #1.** The write path (insert pin, upsert vote, call RPC) involves authenticated requests with a JWT that needs refreshing. Managing that manually in URLSession is fragile and duplicates what the SDK does well. The Tier 1 display layer (`CommunityPinService`) was raw URLSession because it was anonymous read only; the first authenticated write is the natural adoption point. `CommunityPinService` can be migrated to use the same SDK client instance in this PR or a fast-follow PR — engineer's call. |
| OQ-4 | **Anonymous auth persistence across app restarts: where is the session stored?** | (a) Let `supabase-swift` handle it — the SDK's built-in `AuthLocalStorage` stores the session in the iOS Keychain automatically. No extra code needed. (b) Custom Keychain wrapper for consistency with other WePark persistence (all currently `UserDefaults`). | **(a) SDK's built-in Keychain storage.** `supabase-swift` uses `KeychainLocalStorage` by default for iOS. This is more secure than `UserDefaults` (encrypted, device-only) and requires zero custom code. The session persists across app restarts; the anonymous JWT is refreshed automatically. No inconsistency with WePark's existing `UserDefaults` usage because auth tokens are a different category than app state. |

---

## 1. Problem and User Story

**Problem:** Tier 1 is live — users can see filming and ASP pins on the map. But the map is entirely read-only. A user who sees a ticketing officer writing on their block cannot tell WePark, and nobody else can benefit. The trust engine (reactions) is fully plumbed in the DB (`votes` table, `refresh_pin_vote_counts` trigger, `extend_pin_expiry` RPC — all production) but there is no iOS path to write to it.

The blocker is identity. Every write path — insert a pin, cast a vote, extend expiry — requires `auth.uid() is not null` (the `pins_insert_crowd` and `votes_insert_own` RLS policies). Today, the iOS app makes no authentication call. `CommunityPinService` sends only `apikey: <anon-key>` with no `Authorization` header. The anon key satisfies anonymous SELECT but not authenticated INSERT.

**User story (report):**
> A parker on Mott St in SOHO sees a parking enforcement agent walking the block. She taps the map, long-presses the block (W8.5f will wire this; sub-PR #1 builds the underlying service it will call), and in two taps reports "Enforcement active — cleaning truck." The pin appears instantly on every other WePark user's map in the area. She did not create an account. She did not see a login screen. She just tapped twice.

**User story (confirm):**
> A different user drives past Mott St 8 minutes later and sees the enforcement pin with a "8m ago, 0 confirms" badge. She taps "Still there?" The pin's TTL extends by 15 minutes and its confirm count flips to 1. Two other users do the same. The pin is now highly trusted.

**User story (dispute):**
> Three users tap "Gone." The pin's `dispute_count` reaches 3. A server-side trigger sets `resolved_at`. Within 5 seconds the pin disappears from all maps via Realtime. The crowd has collectively resolved the pin — no moderator involved.

**Why now:** This is the first write path in WePark's history. Tier 1 and all prior W-streams were read-only. This sub-PR introduces the identity + write primitive that every subsequent community feature builds on. Sub-PR #2 (patrol mode UI) and sub-PR #3 (decay display) cannot ship anything useful without this.

---

## 2. Scope

### In Scope (sub-PR #1)

- **Supabase Anonymous Auth:** `signInAnonymously()` called on first app launch (or first observed `nil` session). The session is stored in the iOS Keychain by the SDK. No login screen, no email, no user-visible prompt.
- **`SupabaseAuthService`:** new `@Observable` service that wraps the `supabase-swift` client's auth state. Exposes `currentUserId: UUID?` for RLS-aware writes.
- **`supabase-swift` SPM dependency:** added to `WePark.xcodeproj` (minimum version 2.x). Engineer documents the SPM addition in the PR description. No `project.pbxproj` changes committed to the spec — that's engineer territory.
- **`CommunityPinService` authenticated write path:**
  - `insertCrowdPin(type:meta:lat:lng:segmentId:zoneId:notes:)` — POST to `public.pins` with `source = 'crowd'`, `author_id = authService.currentUserId`, `expires_at = now() + 30min` for ephemeral types, `lifespan = 'ephemeral'`.
  - `upsertVote(pinId:vote:)` — POST to `public.votes` on `(pin_id, user_id)` with upsert semantics. Vote values: `'confirm'` or `'dispute'`.
  - `callExtendPinExpiry(pinId:)` — POST to `rpc/extend_pin_expiry` with `{ p_pin_id: <uuid> }`. Only called when the user taps "Still there?" on an ephemeral pin.
- **Auto-resolve trigger (DB migration, @backend-data stream):** a new `supabase/02e-auto-resolve-trigger.sql` that fires on `UPDATE` of `votes.dispute_count` and sets `resolved_at = now()` on the parent pin when `dispute_count >= 3`. This is a separate @backend-data deliverable but belongs in sub-PR #1's scope because AC-T3.4 (dispute-to-resolve flow) is part of this sub-PR's acceptance criteria.
- **Reactions UI scaffolding in `PinDetailSheet`:** the existing TF1 `PinDetailSheet.swift` gets a conditional reactions row when the pin is Tier 3 ephemeral:
  - "Still there?" button → calls `upsertVote(confirm)` + `callExtendPinExpiry`.
  - "Gone" button → calls `upsertVote(dispute)`.
  - Disable both buttons if the pin's `authorId == authService.currentUserId` (OQ-1 iOS guard).
  - Disable "Still there?" if `expiresAt` is already > 1h 55m from now (within 5 min of the 2h cap — no point extending).
  - Confirm-count display: "N confirms" label, updates in real time from `CommunityPinService.visiblePins` (Realtime UPDATE events update `confirmCount`).
- **RLS smoke test:** a new unit test that verifies `upsertVote` sends an `Authorization: Bearer <jwt>` header (not just `apikey`). Verifies the JWT path is wired even if the JWT value is a fixture.

### Out of Scope (Deferred)

- **Patrol mode entry UI, long-press gesture, report sheet** — sub-PR #2 (W8.5f). This PR builds the write services; the UI that calls them is the next PR.
- **Decay visual layer (time-since badge, opacity)** — sub-PR #3 (W8.5g).
- **`open_spot` pin type** — sub-PR #4 (W8.5h). The `open_spot` enum value does not exist in production yet (per OQ-T3-5 in the buildplan, the migration defers to sub-PR #4).
- **Sign in with Apple upgrade flow** — post-TF2.
- **Reputation increment on confirms** — Tier 2 spec (`docs/tier2-reputation-spec.md`). `profiles.reputation` exists in the DB; the increment rule is not yet defined.
- **`broken_meter` pin type** — can be added to the patrol mode report sheet later as a one-line addition; not a blocking dependency.
- **Push notification for pins near parked car** — sub-PR #5 (W8.5i).
- **Drive Mode community callout** — sub-PR #6 (W8.5i).
- **PWA changes** — PWA is in maintenance mode. The anonymous-auth + vote paths are iOS-only.

---

## 3. Architecture

### 3.1 Codebases Touched

| Codebase | Touch? | Notes |
|---|---|---|
| `ios/WePark/WePark/` | Yes | New service + modified service + modified view + new tests |
| `ios/WePark/WeParkTests/` | Yes | Auth + write path + vote unit tests |
| `supabase/` | Yes | New `02e-auto-resolve-trigger.sql` migration (@backend-data) |
| `index.html` (PWA) | No | Maintenance mode |
| `docs/` | This spec | Only this file and the buildplan added |

### 3.2 New Files

```
ios/WePark/WePark/Services/SupabaseAuthService.swift
    — @Observable, wraps supabase-swift auth client
    — signInAnonymously() called on first launch
    — exposes: currentUserId: UUID?, isAuthenticated: Bool, session: Session?
    — called from WeParkApp.swift on app init (not ContentView — avoids body re-render race)

supabase/02e-auto-resolve-trigger.sql
    — @backend-data deliverable
    — adds auto-resolve logic: when dispute_count reaches 3, set resolved_at = now()
    — see §3.3 for the implementation sketch
```

### 3.3 Modified Files

```
ios/WePark/WePark/Services/CommunityPinService.swift
    — add supabase-swift client instance (shared singleton from SupabaseAuthService)
    — add insertCrowdPin(...) async throws
    — add upsertVote(pinId:vote:) async throws
    — add callExtendPinExpiry(pinId:) async throws
    — startRealtime() stub is ACTIVATED: wire supabase-swift RealtimeChannel for
      crowd-type pins (lifespan = 'ephemeral'), not just open_data, so reactions
      from other users flow in real time

ios/WePark/WePark/Views/PinDetailSheet.swift
    — add reactions row (conditional: only for Tier 3 ephemeral pins)
    — "Still there?" button calls authService.currentUserId check then
      communityPinService.upsertVote + callExtendPinExpiry
    — "Gone" button calls communityPinService.upsertVote(.dispute)
    — author-own-pin guard disables both buttons when pin.authorId == authService.currentUserId
    — confirm-count badge (already scaffolded as a TODO comment in TF1) is now wired

ios/WePark/WePark/WeParkApp.swift
    — SupabaseAuthService instantiated as @State at app root
    — .task { await authService.ensureSession() } on first appear — non-blocking,
      fires before ContentView needs auth
    — authService passed into environment or as init param to ContentView
```

### 3.4 Data Flow: Crowd Pin Insert

```
[User long-presses map / taps "Report" — sub-PR #2 will wire this trigger]
        │
        ▼
[CommunityPinService.insertCrowdPin(type: .enforcementActive, meta: ..., lat:, lng:, ...)]
        │
        │ POST /rest/v1/pins
        │ Headers: apikey + Authorization: Bearer <anonymous-jwt>
        │ Body: { pin_type, source: "crowd", lifespan: "ephemeral",
        │         lat, lng, author_id: currentUserId,
        │         expires_at: ISO-now+30min,
        │         meta: { sub_tag: "cleaning_truck" } }
        ▼
[Supabase: pins_insert_crowd RLS policy passes (auth.uid() = author_id AND source = 'crowd')]
        │
        │ Realtime INSERT event broadcast to all subscribers
        ▼
[All other users' CommunityPinService.mergeRealtimeChange(pin:)]
        │
        ▼ (pin passes clientSideFilter — not expired, not resolved)
[visiblePins updated → .onChange fires → MapViewRepresentable adds MKAnnotation]
```

### 3.5 Data Flow: Vote / Confirm

```
[User taps "Still there?" on PinDetailSheet]
        │
        ├─► CommunityPinService.upsertVote(pinId: pin.id, vote: "confirm")
        │       POST /rest/v1/votes
        │       Body: { pin_id, user_id: currentUserId, vote: "confirm" }
        │       On conflict (pin_id, user_id): update set vote = "confirm"
        │       → votes_refresh_pin_counts trigger fires → pins.confirm_count++
        │       → Realtime UPDATE on pins row → all clients see confirmCount increment
        │
        └─► CommunityPinService.callExtendPinExpiry(pinId: pin.id)
                POST /rest/v1/rpc/extend_pin_expiry
                Body: { p_pin_id: pin.id }
                → expires_at += 15 min (capped at now+2h)
                → Realtime UPDATE on pins row → all clients see expiresAt extend
```

### 3.6 Data Flow: Dispute / Auto-Resolve

```
[User taps "Gone" on PinDetailSheet]
        │
        ▼
CommunityPinService.upsertVote(pinId: pin.id, vote: "dispute")
        │
        ▼
votes_refresh_pin_counts trigger → pins.dispute_count++
        │
        ▼
auto_resolve_on_dispute trigger (new in 02e-auto-resolve-trigger.sql):
    if dispute_count >= 3 AND resolved_at IS NULL:
        UPDATE pins SET resolved_at = now() WHERE id = pin.id
        │
        ▼
Realtime UPDATE event (resolved_at now non-null) → all clients'
CommunityPinService.mergeRealtimeChange:
    resolved pin → visiblePins.removeAll { $0.id == pin.id }
    → .onChange fires → MKAnnotation removed from map
```

### 3.7 New DB Migration: `02e-auto-resolve-trigger.sql` (@backend-data)

```sql
-- supabase/02e-auto-resolve-trigger.sql
-- Auto-resolves a pin when dispute_count reaches the threshold (3 for TF1).
-- Fires after the votes_refresh_pin_counts trigger has already updated counts.
-- @backend-data implements; sketch only.

create or replace function public.auto_resolve_on_dispute()
returns trigger language plpgsql security definer as $$
begin
  -- Only act on ephemeral pins not already resolved.
  if new.dispute_count >= 3 and new.resolved_at is null
     and new.lifespan = 'ephemeral' then
    update public.pins
    set resolved_at = now(), updated_at = now()
    where id = new.id;
  end if;
  return null;
end;
$$;

drop trigger if exists pins_auto_resolve_on_dispute on public.pins;
create trigger pins_auto_resolve_on_dispute
  after update of dispute_count on public.pins
  for each row execute function public.auto_resolve_on_dispute();
```

**Note:** The trigger fires on the `pins` table after `dispute_count` is updated by the already-existing `votes_refresh_pin_counts` trigger. The two-trigger chain is: `votes` INSERT → `refresh_pin_vote_counts` → `pins.dispute_count++` → `auto_resolve_on_dispute` → `pins.resolved_at = now()`. Both triggers are `SECURITY DEFINER`, which is already established for `refresh_pin_vote_counts` in `supabase/02-pins-schema.sql:215`. The migration is idempotent (`CREATE OR REPLACE` + `DROP TRIGGER IF EXISTS`).

### 3.8 `SupabaseAuthService` Interface Sketch

```swift
// ios/WePark/WePark/Services/SupabaseAuthService.swift
// @ios-engineer implements; sketch only.

import Supabase  // supabase-swift SPM package

@MainActor
@Observable
final class SupabaseAuthService {

    // The shared Supabase client used by both auth and PostgREST / Realtime.
    // Single instance — do not instantiate multiple SupabaseClients.
    let client: SupabaseClient

    private(set) var currentUserId: UUID? = nil
    private(set) var isAuthenticated: Bool = false

    init() {
        // URL + key read from Info.plist (same Config.xcconfig bridge as CommunityPinService).
        // Using the SAME keys: SUPABASE_URL + SUPABASE_ANON_KEY.
        let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""
        self.client = SupabaseClient(
            supabaseURL: URL(string: urlString)!,
            supabaseKey: key
        )
        // Observe auth state changes to keep currentUserId in sync.
        Task { await observeAuthState() }
    }

    /// Ensures an active session. Called on app init.
    /// If no session exists, calls signInAnonymously(). Non-blocking from the caller's perspective.
    func ensureSession() async {
        do {
            let session = try await client.auth.session
            currentUserId = session.user.id
            isAuthenticated = true
        } catch {
            // No session — create an anonymous one.
            await signInAnonymously()
        }
    }

    private func signInAnonymously() async {
        do {
            let session = try await client.auth.signInAnonymously()
            currentUserId = session.user.id
            isAuthenticated = true
        } catch {
            // Fail silently for TF1; log in production.
            // UI should remain functional in read-only mode if auth fails.
        }
    }

    private func observeAuthState() async {
        for await (event, session) in client.auth.authStateChanges {
            if event == .signedIn || event == .tokenRefreshed {
                currentUserId = session?.user.id
                isAuthenticated = session != nil
            } else if event == .signedOut {
                currentUserId = nil
                isAuthenticated = false
                // Re-establish anonymous identity immediately.
                await signInAnonymously()
            }
        }
    }
}
```

**Key design points:**

- Single `SupabaseClient` instance. `CommunityPinService` receives the same `client` reference (injected at init or via environment) — no second Supabase connection.
- `currentUserId` is the `UUID` from `auth.uid()` in the JWT. This is what gets written as `author_id` on new pins and `user_id` on votes.
- Auth state is observed via the SDK's `authStateChanges` async stream — the app recovers automatically if the token is refreshed or the user is signed out.
- No UI is shown to the user at any point in this flow.

### 3.9 `CommunityPinService` Write-Path Additions (interface sketch)

The existing `CommunityPinService` (read-only at `ios/WePark/WePark/Services/CommunityPinService.swift`) gains three new async methods. The raw `URLSession` fetch path for reads is preserved — the engineer can choose whether to migrate reads to `supabase-swift`'s `client.from(...)` query builder or leave them as-is. Document the choice in the PR.

```swift
// Sketch — @ios-engineer implements.
// These methods live in CommunityPinService.swift alongside the existing fetch/filter code.

/// Inserts a new crowd-sourced pin. Throws on network or RLS failure.
/// Caller (sub-PR #2 patrol mode report sheet) is responsible for the UX around errors.
func insertCrowdPin(
    type: PinType,
    meta: PinMeta?,
    lat: Double,
    lng: Double,
    segmentId: String?,
    zoneId: String?,
    notes: String?
) async throws {
    guard let userId = authService.currentUserId else {
        throw CommunityPinWriteError.notAuthenticated
    }
    let expiresAt: Date? = {
        switch type {
        case .enforcementActive, .sweeperPassed, .openSpot:
            return nowProvider().addingTimeInterval(30 * 60)  // 30 min
        default:
            return nil
        }
    }()
    // Build the insert payload and POST to /rest/v1/pins via authService.client
    // or raw URLSession with Authorization: Bearer header from the JWT.
    // Engineer's choice on the API style; JWT must be included.
}

/// Upserts a vote on (pinId, userId). Changing vote = upsert semantics (conflict update).
/// Also triggers extend_pin_expiry if vote == "confirm" and pin is ephemeral.
func upsertVote(pinId: UUID, vote: VoteType) async throws {
    guard let userId = authService.currentUserId else {
        throw CommunityPinWriteError.notAuthenticated
    }
    // POST /rest/v1/votes with Prefer: resolution=merge-duplicates header for upsert.
    // Body: { pin_id, user_id, vote }
}

/// Calls the extend_pin_expiry RPC for an ephemeral pin.
func callExtendPinExpiry(pinId: UUID) async throws {
    // POST /rest/v1/rpc/extend_pin_expiry
    // Body: { p_pin_id: pinId.uuidString }
    // No return value; errors on non-ephemeral pin or expired pin (silent no-op per RPC).
}

enum VoteType: String {
    case confirm = "confirm"
    case dispute = "dispute"
}

enum CommunityPinWriteError: Error {
    case notAuthenticated
    case httpError(statusCode: Int)
    case encodingFailure
}
```

### 3.10 `PinDetailSheet` Reactions Row

The existing `PinDetailSheet.swift` (created in PR #37) shows read-only pin info. The reactions row is added conditionally:

```swift
// Sketch — inside PinDetailSheet.swift body.
// Condition: only show for Tier 3 ephemeral crowd pins.
if pin.lifespan == .ephemeral && pin.source == .crowd {
    ReactionsRow(
        pin: pin,
        currentUserId: authService.currentUserId,
        onStillHere: {
            Task {
                try? await pinService.upsertVote(pinId: pin.id, vote: .confirm)
                try? await pinService.callExtendPinExpiry(pinId: pin.id)
            }
        },
        onGone: {
            Task {
                try? await pinService.upsertVote(pinId: pin.id, vote: .dispute)
            }
        }
    )
}
```

`ReactionsRow` is a new private `View` within `PinDetailSheet.swift` (or a separate `Views/ReactionsRow.swift` — engineer's call). It renders:

- "Still there?" button (confirm icon + label). Disabled if `pin.authorId == currentUserId` OR `pin.expiresAt ?? .distantFuture > nowProvider().addingTimeInterval(115 * 60)` (already near the 2h cap).
- "Gone" button (dispute icon + label). Disabled if `pin.authorId == currentUserId`.
- "N confirms" text label, reading from `pin.confirmCount` (updated in real time via Realtime).
- Loading state: while either async call is in-flight, show a `ProgressView` in place of the confirm count badge.

**One-tap design principle** (per `community-1.0-direction.md §6.1`): the tap targets are large (44pt minimum HIG), single-action, binary. No confirmation sheet, no emoji palette. The button fires immediately.

---

## 4. `open_spot` Enum Migration — Status and Defer Rationale

`open_spot` is NOT in the current `pin_type` enum in production. The 10 existing values are:
`filming`, `asp_suspended_today`, `special_event`, `construction`, `sign_correction`, `block_note`, `enforcement_active`, `sweeper_passed`, `broken_meter`, `parked_car`.

Adding `open_spot` requires:

```sql
-- NOT in this sub-PR — deferred to sub-PR #4 per OQ-T3-5
ALTER TYPE public.pin_type ADD VALUE 'open_spot';
```

This DDL cannot be executed inside a transaction block in Postgres (it commits immediately). Per OQ-T3-5 decision in `docs/tier3-patrol-mode-buildplan.md`: defer the migration to sub-PR #4, when the full `open_spot` reporting UI + claim mechanic is being built. This avoids the enum value existing in the DB without any RLS, iOS model case, or UI to handle it.

The iOS `PinType` enum in `Models/CommunityPin.swift` is FROZEN per AC-D20 of the Tier 1 display spec. Adding `.openSpot` is sub-PR #4's iOS model work. This spec does not touch `CommunityPin.swift`.

---

## 5. Realtime Subscription Upgrade

The existing `CommunityPinService.startRealtime()` is a stub (see `CommunityPinService.swift:193–199`) left with a `TODO` comment for post-prod-apply activation. This sub-PR activates it.

The subscription must be extended beyond `source = 'open_data'` to include `lifespan = 'ephemeral'` crowd pins (enforcement, sweeper), because reactions and confirms from OTHER users need to propagate in real time:

```swift
// Activate in startRealtime() — replaces the stub.
// Two channels: open_data (Tier 1) + ephemeral crowd (Tier 3).
// These are OR'd together — supabase-swift supports filter conditions on channels.

// Channel 1: open_data pins (Tier 1, existing)
supabase.realtime.channel("public:pins:open_data")
    .on(.postgresChanges, filter: .init(event: .all, schema: "public", table: "pins",
        filter: "source=eq.open_data")) { [weak self] payload in
        self?.handleRealtimeChange(payload)
    }.subscribe()

// Channel 2: ephemeral crowd pins (Tier 3 — enforcement, sweeper)
supabase.realtime.channel("public:pins:ephemeral_crowd")
    .on(.postgresChanges, filter: .init(event: .all, schema: "public", table: "pins",
        filter: "lifespan=eq.ephemeral")) { [weak self] payload in
        self?.handleRealtimeChange(payload)
    }.subscribe()
```

The existing `mergeRealtimeChange(pin:)` method handles both INSERT and UPDATE events (including `confirm_count` / `expires_at` / `resolved_at` changes) without modification — it already dispatches correctly on `pin.resolvedAt` and `clientSideFilter`.

---

## 6. Work Streams

Two parallel streams within sub-PR #1. They are file-disjoint and can start simultaneously once Kevin approves the OQ table.

| Stream | Owner | Dependencies | Parallel with | Notes |
|---|---|---|---|---|
| **A — iOS auth + write path** | @ios-engineer | Kevin OQ approval, `supabase-swift` SPM added | Stream B | New `SupabaseAuthService.swift` + `CommunityPinService` write additions + `PinDetailSheet` reactions row + unit tests + SPM setup |
| **B — Auto-resolve trigger** | @backend-data | Kevin OQ-2 threshold decision | Stream A | New `supabase/02e-auto-resolve-trigger.sql` + QA verification per AC-DB1–DB3 |

Stream A can be built and unit-tested against fixtures without Stream B being live. The integration test (full dispute-to-resolve flow) requires Stream B applied to production.

---

## 7. Acceptance Criteria

All ACs verified by @qa-verifier independently. @qa-verifier is not the same agent that built the feature.

### Anonymous Auth (Stream A, unit/integration)

- [ ] **AC-A1.** On first launch (no prior session in Keychain), `SupabaseAuthService.ensureSession()` calls `signInAnonymously()` and sets `currentUserId` to a non-nil `UUID` without any user-visible prompt or screen. Verified by observing `currentUserId != nil` after `ensureSession()` resolves in a test with a mock auth client.
- [ ] **AC-A2.** On subsequent launch (session exists in Keychain), `ensureSession()` restores the existing session without a new `signInAnonymously()` call. `currentUserId` is the same UUID across restarts. Verified in a unit test with a mock that returns a pre-seeded session.
- [ ] **AC-A3.** If the SDK returns a sign-out event (token invalidated), `signInAnonymously()` is called automatically and `currentUserId` is updated to a new anonymous UUID. Verified by injecting a `.signedOut` event into the mock auth state stream.
- [ ] **AC-A4.** No login screen, email field, username field, or authentication-related UI is presented at any point. Verified by code review — no `NavigationLink`, no `Sheet`, no `Alert` in `SupabaseAuthService.swift`.
- [ ] **AC-A5.** The `SupabaseClient` instance is a singleton (one instance per app lifetime). Verified by inspecting that `SupabaseAuthService` is instantiated once in `WeParkApp.swift` and the same client reference is passed to `CommunityPinService`.

### Write Path — Insert (Stream A)

- [ ] **AC-W1.** `insertCrowdPin(type: .enforcementActive, ...)` builds a URLRequest (or SDK call) that includes `Authorization: Bearer <jwt>` with a non-empty JWT string. Verified by inspecting the outgoing request in a unit test with `MockURLProtocol` or the SDK's request interceptor.
- [ ] **AC-W2.** The insert payload includes `source = "crowd"`, `author_id = currentUserId`, `lifespan = "ephemeral"`, and `expires_at = ISO8601(now + 30 minutes)`. Verified by decoding the request body in a unit test.
- [ ] **AC-W3.** `insertCrowdPin` with `authService.currentUserId == nil` throws `CommunityPinWriteError.notAuthenticated` without making a network call.
- [ ] **AC-W4.** (End-to-end, requires prod schema + live auth) An `enforcement_active` pin inserted via `insertCrowdPin` appears in a second client's `visiblePins` array within 5 seconds (Realtime delivery). Verified manually by Kevin or two simultaneous sim sessions.

### Write Path — Vote (Stream A)

- [ ] **AC-V1.** `upsertVote(pinId:, vote: .confirm)` builds a request with `Prefer: resolution=merge-duplicates` header (PostgREST upsert semantics). Verified by request inspection in unit test.
- [ ] **AC-V2.** Tapping "Still there?" on an ephemeral pin calls BOTH `upsertVote(.confirm)` AND `callExtendPinExpiry`. Verified by a unit test that mocks both write methods and asserts both were called.
- [ ] **AC-V3.** Tapping "Gone" calls ONLY `upsertVote(.dispute)` (not `callExtendPinExpiry`). Verified similarly.
- [ ] **AC-V4.** "Still there?" and "Gone" buttons are disabled when `pin.authorId == authService.currentUserId`. Verified by rendering `ReactionsRow` in a test with matching IDs and asserting both buttons have `.disabled == true`.
- [ ] **AC-V5.** (End-to-end) After tapping "Still there?", the `confirm_count` badge in `PinDetailSheet` increments within 5 seconds (Realtime UPDATE propagation). Verified in Kevin's manual smoke.
- [ ] **AC-V6.** (End-to-end) After tapping "Still there?", the `expires_at` on the pin extends by 15 minutes. Verified by reading the pin's `expires_at` from the DB before and after the tap.

### Auto-Resolve Trigger (Stream B)

- [ ] **AC-DB1.** Inserting 3 dispute votes on an `enforcement_active` pin sets `resolved_at` on the pin within the same Postgres transaction (trigger fires synchronously). Verified in the Supabase SQL editor: `SELECT resolved_at FROM pins WHERE id = <test-pin-id>` after inserting 3 dispute rows.
- [ ] **AC-DB2.** Inserting 2 dispute votes does NOT set `resolved_at`. Verified similarly.
- [ ] **AC-DB3.** The trigger does NOT fire on durable-lifespan pins (e.g., a `sign_correction` with 3 disputes retains `resolved_at = null`). Verified by inserting 3 dispute votes on a durable pin and confirming `resolved_at` is still null.
- [ ] **AC-DB4.** `02e-auto-resolve-trigger.sql` is idempotent: running it twice produces no errors. Verified by running it twice in the SQL editor.

### Architecture Invariants (code review + existing tests)

- [ ] **AC-I1.** `SupabaseAuthService.swift` contains no `Calendar.current` usage. All time math (e.g., `expires_at = now + 30min`) uses `nowProvider()` injectable or `Date()` only — no `Calendar` arithmetic.
- [ ] **AC-I2.** `CommunityPin.swift` is NOT modified. The frozen model contract from PR #36 holds (AC-D20 from Tier 1 spec). Write-path additions live in `CommunityPinService.swift` only.
- [ ] **AC-I3.** `PinDetailSheet.swift` modifications do not add any `setRegion`, `updateUIView` mutation, or `headlessWindow` guard.
- [ ] **AC-I4.** `RegionSyncGuardTests` (2 tests) pass unchanged after this PR. Verified by running the test suite.
- [ ] **AC-I5.** No new `Calendar.current` usage anywhere in the PR diff.
- [ ] **AC-I6.** The Supabase anon key is NOT committed to any source file. It remains in `Config.xcconfig` (gitignored). `Config.xcconfig.example` documents `SUPABASE_URL` and `SUPABASE_ANON_KEY` key names (no change needed; already documented from Tier 1).

### Live-UI Smoke Gate

- [ ] **AC-S1.** If `PinDetailSheet.swift` or `ContentView.swift` is modified in this PR: engineer builds + launches in Simulator, captures screenshot via `xcrun simctl io booted screenshot /tmp/tier3-auth-reactions-smoke.png`, reads the screenshot with the Read tool. Screenshot confirms: (a) ASP banner still renders at the top, (b) toolbar layer (gear / find-me / find-car / clock / Drive button) is visible, (c) no overlay elements dropped. This gate is MANDATORY before the PR is opened. @qa-verifier repeats independently.

---

## 8. Open Decisions — `open_spot` Notes for @backend-data

This spec defers `open_spot` to sub-PR #4 (per OQ-T3-5). @backend-data should note that the eventual migration requires:

1. `ALTER TYPE public.pin_type ADD VALUE 'open_spot';` — applied OUTSIDE a transaction block.
2. The `open_spot` default `expires_at` is `now() + interval '3 minutes'` (not 30 minutes like enforcement/sweeper) — this is the shortest TTL in the system. The `insertCrowdPin` iOS function will need a new case for this value in its `expires_at` computation.
3. A `claim` mechanic: a separate table or `meta` field to record "user X is heading to this spot" — dims the pin marker for the claiming user. This is a TBD design at this spec's writing; sub-PR #4 spec will define it.
4. SOHO/LES zone filter: the `pins_insert_crowd` RLS does not enforce zone restrictions. The iOS layer will enforce it (check `zone_id == 'soho-les'`); optionally add a server-side check in sub-PR #4 if Kevin wants a hard enforcement point.

---

## 9. Out-of-Scope Follow-Ups

**Reputation increment.** When a crowd pin receives its 3rd confirm, the `author_id`'s `profiles.reputation` should increment by 2 (per `community-1.0-buildplan.md §3` Tier 2 reputation rules). This is a Tier 2 concern — `profiles.reputation` exists, the rule is not yet encoded. Do not add reputation logic to this sub-PR. A `// TODO: Tier 2 — increment author reputation on 3rd confirm` comment in `02e-auto-resolve-trigger.sql` marks the seam.

**Supabase Swift SDK migration for reads.** `CommunityPinService`'s fetch path is raw URLSession (`buildRequest` / `decodeResponse`). Once `supabase-swift` is an SPM dependency, migrating the read path to use `client.from("pins_with_author").select(...)` is a clean-up worth doing — but it changes no behavior and should be a separate, mechanical PR. Not in sub-PR #1 scope.

**Anonymous auth + Apple Sign-In upgrade path.** The `supabase-swift` SDK supports linking an anonymous session to a Sign-In-with-Apple credential via `client.auth.linkIdentity(credentials: .apple(...))`. The anonymous `currentUserId` is preserved. This is post-TF2; the seam is the SDK itself. No code scaffolding needed now.

**Vote retraction.** A user who tapped "Gone" and wants to change to "Still there?" can do so — the `upsertVote` path already handles this (conflict update). The UI doesn't need a special "undo" button; tapping the opposite button upserts over the existing vote. This is implicit behavior; make sure the engineer documents it in a comment.
