# iCloud Parked-Car Sync — Spec

**Status:** Ready to build. Kevin approved the feature and the `NSUbiquitousKeyValueStore` approach
(`docs/open-items.md` 2026-08-20 build-plan addendum). This spec exists to remove the re-derivation
cost `docs/build-18-sizing.md` §2 flagged: the merge/tombstone policy is the real work, and it was
underspecified, not un-built. This doc makes it buildable.

**Supersedes:** nothing. First spec for this feature. Sizing precursor: `docs/build-18-sizing.md` §2,
§7, §8 (risks #2 and #3), §9.

---

## 0. Read this before writing any code — three things need Kevin's yes/no

1. **Merge comparator is `updatedAt`, a NEW envelope-level timestamp — not raw `ParkedCar.parkedAt`.**
   Kevin's ruling was "last-write-wins by `parkedAt`." This spec implements that ruling but adds one
   layer: a fresh park's `updatedAt` **equals** `car.parkedAt`, so the ruling holds exactly for the
   normal case. But the per-pin notify toggle (`updateNotifyOnRestriction`) and the clear-tombstone
   both need *some* timestamp to participate in last-write-wins, and neither is a "new park" — they'd
   never win against a genuine `parkedAt` under the literal reading, and edits like the toggle would
   never propagate cross-device at all. §3.1 below has the full reasoning. **Needs a one-line yes.**
2. **`AccountChange` (user switches iCloud accounts mid-session) is handled identically to a normal
   remote update** — adopt whatever's now in the store via the same merge check, no special-casing.
   Rare edge case (see §6 OQ-2), but deciding it silently is exactly the pattern this project's specs
   keep flagging. **Needs a one-line yes or a different ruling.**
3. **On a remote change to the car currently open in `ParkedCarDetailView`, the sheet is dismissed**,
   not refreshed in place. Simplest and safest; a live-refresh is possible later if wanted. **Needs a
   one-line yes** (§6 OQ-3).

None of these block starting the code — they block *merging* it. Flag them to Kevin now so the answer
is waiting when the PR is ready, not discovered mid-review.

**Also found while reading the code, worth Kevin's attention before dispatch:** there is no
`.entitlements` file anywhere in `ios/WePark/` and no iCloud capability configured in
`project.pbxproj` (verified — grepped for `Ubiquity`/`CODE_SIGN_ENTITLEMENTS`/`com.apple.developer`,
zero hits). `NSUbiquitousKeyValueStore` requires the **iCloud → Key-value storage** capability, added
in Xcode's Signing & Capabilities tab, which needs the App ID's iCloud capability enabled (Xcode
usually does this automatically with Automatic Signing, but Kevin should expect an Xcode prompt/step).
**This is a Mac-only, one-time setup step no VPS agent can perform**, and it's silent if skipped —
without it, `NSUbiquitousKeyValueStore.default` still compiles, still reads/writes locally, and
**never syncs, with no error.** See §4 Work Stream 0.

---

## 1. Problem & user story

Today the parked car is one JSON blob in `UserDefaults.standard`
(`ios/WePark/WePark/Services/ParkPinService.swift:45-46`), scoped to the single device's app
container. Two consequences, both now real per `HANDOFF.md`'s 2026-08-20 entry ("WePark is public" —
build 16 passed Beta App Review, external TestFlight users exist):

- **A user cannot see their car on a second device.** Someone with an iPhone and an iPad who parks
  from their phone gets nothing on the iPad.
- **A user loses their car permanently on delete-and-reinstall.** No account exists to recover it —
  strangers using this app have no path back to their parked-car state if they ever remove the app.

Kevin chose `NSUbiquitousKeyValueStore` explicitly **over an account system**
(`docs/open-items.md`, "🆕 BUILD 18 SCOPE ADDED 2026-08-20"): no login, no sign-up UI, tied to the
Apple ID rather than the app container, close to a drop-in swap for the existing store. **This spec
does not add accounts, Sign in with Apple, or any auth UI.** The zero-friction "open it and see the
map" onboarding is a protected product property, not incidental.

**User story:** I park my car from my phone. I pick up my iPad later and my car is still there — same
street, same side, same "leaves at 8:45 AM" countdown — with nothing I had to do to make that happen.
If I clear my car from either device, it's gone from both.

---

## 2. Scope

**In:**
- Replace `UserDefaults.standard` with `NSUbiquitousKeyValueStore.default` as the sole backing store
  for the active parked-car state, behind an injectable protocol seam for testability.
- One-time migration of an existing device's legacy `UserDefaults` car into the new store.
- Last-write-wins merge policy (§3.1) with an explicit tombstone for "cleared" (§3.2) — the two things
  `docs/build-18-sizing.md` named as the real risk.
- Correct interaction with the existing `firstPinDropped`/`pinDropped` Combine hooks and the
  `NotificationScheduler` cancel/reschedule chain, so a remote-arrived car doesn't double-schedule
  reminders, doesn't orphan a device's existing reminders, and doesn't trigger the W6 first-pin
  rationale sheet or the W7.5 "Parking until when?" auto-prompt (§3.3 — traced against real code).
- A testability seam (`UbiquitousKeyValueStoring` protocol) so the merge/tombstone/migration logic —
  the hard part — is unit-testable without real iCloud or a second device.
- One-time Xcode capability setup (Mac-only, Kevin's hands).

**Out (explicitly, with rationale):**
- **Accounts, Sign in with Apple, anonymous→account migration.** Kevin's own framing — see §0 of
  `docs/open-items.md`'s 2026-08-20 entry: "The long-term shape if ever needed: anonymous by default,
  optional Sign in with Apple that *links* the existing anonymous identity." Not this feature.
- **Any new UI.** No "synced from your other device" badge, no settings toggle to disable sync, no
  conflict-resolution UI. This is meant to be invisible.
- **Syncing anything other than the active parked-car state.** Per-device notification preferences,
  the notification-rationale-shown flag, and the first-pin-ever flag are deliberately device-local —
  see §3.4.
- **A CloudKit-backed history of past parking sessions.** Single-pin model, unchanged — one active car,
  same as today.
- **Any change to `CommunityPin`/crowd-reporting data.** Unrelated system, different service
  (`CommunityPinService`), not touched.

---

## 3. Architecture

**Codebase touched: iOS only.** No backend, no PWA. `NSUbiquitousKeyValueStore` is entirely
client-side and Apple-account-scoped — there is no server component, no Supabase table, no RPC.

**Files:**
- **New:** `ios/WePark/WePark/Models/SyncedCarEnvelope.swift` — the wire format.
- **Rewritten:** `ios/WePark/WePark/Services/ParkPinService.swift` — storage backend swap +
  migration + merge logic + new publisher.
- **Small addition:** `ios/WePark/WePark/Services/NotificationScheduler.swift` — one new method,
  `cancelAll(forUUID:)`.
- **Moderate addition:** `ios/WePark/WePark/ContentView.swift` — one new `.onReceive`, one new
  handler, generalize `previousCarID` bookkeeping, one new stale-sheet-dismiss branch.
- **New:** `ios/WePark/WeParkTests/ParkPinServiceSyncTests.swift`. Note: **`ParkPinService` currently
  has zero unit test coverage** — W5 QA Finding #3 flagged this as optional and it was never picked
  up (confirmed: no `ParkPinServiceTests.swift` exists anywhere under `WeParkTests/`). This rewrite
  needs to also cover the *unchanged* local save/load/clear behavior as regression protection, not
  just the new sync logic — there is no existing safety net for this file at all.
- **Kevin, Mac-only, one time:** add the iCloud → Key-value storage capability in Xcode. Produces a
  new `.entitlements` file that gets committed (§4 Work Stream 0).
- **Not touched:** `ParkedCar.swift` (no new fields needed — see §3.1, the envelope wraps it rather
  than extending it), `Constants.swift`, anything under `supabase/`, `index.html`.

### 3.1 The storage contract

**One key, one envelope, in `NSUbiquitousKeyValueStore.default`:**

```swift
// Models/SyncedCarEnvelope.swift
struct SyncedCarEnvelope: Codable, Equatable {
    enum Kind: String, Codable { case parked, cleared }

    let kind: Kind

    /// Merge comparator (see §0.1). NOT the same field as car.parkedAt — bumped on
    /// EVERY write to the envelope: a fresh park, a per-pin notify-toggle edit, or a
    /// clear. For a fresh `.parked` envelope, updatedAt == car.parkedAt, so "the most
    /// recent park wins" (Kevin's ruling) holds exactly in the normal case.
    let updatedAt: Date

    /// Present iff kind == .parked. nil for .cleared (the tombstone).
    let car: ParkedCar?
}
```

Key name: `wepark_synced_car_state`. `ParkedCar` itself is unchanged — the envelope wraps it, so no
existing `ParkedCar` call site (there are several: `ParkConfirmView`, `ParkedCarDetailView`,
`NotificationScheduler`, `ContentView`) needs to change its signature.

**Why a wrapper and not just `ParkedCar` directly with a nullable-key-means-cleared convention:**
that's exactly the bug this feature would otherwise ship with — see §3.2.

**`NSUbiquitousKeyValueStore`'s real constraints, stated so nobody discovers them mid-incident:**
- **Total quota: 1 MB across all keys for the app, per Apple's documented limit** (individual value
  size is bounded by the same 1 MB total, not separately larger). A `SyncedCarEnvelope` for a
  realistic `ParkedCar` — UUID, two doubles, a segment ID, a side code, three street-name strings,
  an ISO8601 timestamp, a bool — serializes to a few hundred bytes. **AC-16 pins this with a unit
  test** (assert encoded size stays under a conservative 2 KB threshold) as a canary, since the
  actual risk here is near zero but "near zero" isn't the same as "verified."
- **It is best-effort, not guaranteed delivery.** A local `set(_:forKey:)` call updates the value
  **immediately and reliably within the writing process** — the writing device's own `parkedCar`
  is correct the instant `save()` returns, with or without iCloud. Propagation to *other* devices
  depends on iCloud account state, network, and OS-level sync timing that this app has no control
  over and no visibility into. `synchronize()` is a best-effort hint to pull down the latest value
  sooner; it is not synchronous and does not guarantee anything completes before it returns.
  **What this means concretely: a user with no iCloud account, or iCloud disabled for this app,
  gets the exact same single-device experience as today — write succeeds locally, nothing crashes,
  nothing degrades — they just never see cross-device sync.** That's the correct fallback, and it
  falls out of the API for free; nothing needs to be built to detect "no iCloud" as a special case.
- **`NSUbiquitousKeyValueStoreDidChangeExternallyNotification`'s reason codes need distinct
  handling**, read from `userInfo[NSUbiquitousKeyValueStoreChangeReasonKey]`:
  - `ServerChange` / `InitialSyncChange` — a real remote update. Run the merge check (§3.1's
    `updatedAt` comparison).
  - `AccountChange` — the signed-in iCloud account changed on this device. See §0.2/§6 OQ-2:
    default is to treat identically to the above (adopt via the same merge check), not special-cased.
  - `QuotaViolationChange` — irrelevant at this payload size (see quota note above), but handled
    defensively: log and return, no partial write, no crash (AC-15). This is a one-line guard, not
    a feature.

### 3.2 The tombstone — why absence cannot mean "no car"

**This is the bug `docs/build-18-sizing.md` named as the one this feature would ship with if built
naively.** If clearing the car just removed the key (or wrote nothing), here's the failure: user
clears their car on their phone (`clearPin()`). Their iPad, offline at that moment, still holds the
old car in its last-synced snapshot. When the iPad reconnects, nothing tells it "the key is now
absent because it was intentionally cleared" versus "the key is absent because this device has never
synced a value yet" (the exact same observable state as a fresh install with a remote car pending)
— those two cases are indistinguishable without an explicit marker. The iPad's own next write (or
even just redisplaying its stale in-memory state) would re-plant a car the user deliberately removed.

**Fix: `clearPin()` writes a `.cleared` envelope — a tombstone with its own `updatedAt` — instead of
deleting the key.** A tombstone is a real value in the store, participates in the same last-write-wins
comparison as a `.parked` envelope, and can itself be **superseded** by a later park (user clears on
device A, then parks again on device B ten minutes later — the new `.parked` envelope has a later
`updatedAt` and wins, correctly un-tombstoning). Absence of the key (never written) and presence of a
`.cleared` tombstone are the *only* two representations of "no car," and only the second one is ever
produced by a deliberate user action — `applyRemoteChange()` (§3.5) treats a genuinely absent/corrupt
key as a no-op, never as an implicit clear (AC-verified — see §5).

### 3.3 The full state matrix

| # | Local (this device's last-applied state) | Remote (what's in the store / arrives) | Result the user sees |
|---|---|---|---|
| 1 | Car A, `parkedAt` T1 | Car B, `parkedAt` T2, T2 > T1 | Car B replaces Car A. Reminders rescheduled for Car B on this device. No first-pin sheet, no Park-Until auto-prompt. |
| 2 | Car A, T1 | Car B, T2, T2 < T1 (stale delivery — §3.1's "iCloud delivers a stale value after a local save" case) | **Nothing changes.** Car A stays. This is the guard decision #1 exists for. |
| 3 | Car A, `updatedAt` T1 | Tombstone, T2 > T1 | Car A is cleared. This device's pending reminders for Car A are cancelled. If `ParkedCarDetailView` was open for Car A, it's dismissed (§3.3.1). |
| 4 | Tombstone, T1 | Car B, T2 > T1 | Car B appears. Reminders scheduled per this device's own permission/mute/offset state (§3.4). |
| 5 | Neither ever written (fresh pair, nobody has parked) | — | No car. Identical to today's fresh-install state. |
| 6 | Fresh device, never launched before, no legacy `UserDefaults` blob | Store already holds Car B from another device | **Car B appears immediately on first launch, with no action from this device's user.** This is the feature's whole point (§1's user story) — verified as its own acceptance criterion (AC-20), not folded into the generic "remote update" case, because a first-launch apply has no "old car" to reconcile against and must not be gated by anything migration-related. |
| 7 | Legacy `UserDefaults` car present (pre-upgrade device), store empty | (none — this is the first-ever write for this Apple ID) | Migration: legacy car becomes the store's first `.parked` envelope, `updatedAt` = its own `parkedAt`. Legacy `UserDefaults` key removed. |
| 8 | Legacy `UserDefaults` car present, store **already** holds a different envelope (this Apple ID's *other* device already upgraded and parked/cleared first) | as above | **Not a special case.** The legacy blob is treated as this device's local candidate and run through the exact same last-write-wins comparison as case 1/2 — see §3.6. Whichever `updatedAt` is later wins, regardless of "legacy" vs "cloud" origin. |

**3.3.1 — the sheet-staleness edge case, named explicitly because it's easy to miss:**
`ParkedCarDetailView` is presented via `activeSheet == .parkedCarDetail(let car)`
(`ContentView.swift:1000-1001`), where `car` is a **value-type snapshot** captured at presentation
time. If a remote change replaces or clears that exact car while the sheet is open, the sheet has no
way to know — SwiftUI doesn't re-diff an already-captured associated value. Left alone, the user would
see a detail sheet for a car that (from the app's own state) no longer exists, including a live "I
left" button that would double-clear an already-cleared car. **Fix (per §0.3's ruling): if the car
being replaced/cleared by a remote change matches the `id` of whatever's currently shown in
`.parkedCarDetail`, dismiss the sheet** the same way `onDismiss`/`onClearPin` already do
(`activeSheet = dismissTargetOutsideBrowseNav`, `ContentView.swift:1010-1014`).

### 3.4 What is deliberately NOT synced, and why

| Not synced | Where it lives | Why |
|---|---|---|
| `hasEverParkedKey` (`wepark_has_ever_parked`) | `UserDefaults.standard`, unchanged | Gates the W6 notification-permission rationale sheet (`ParkPinService.swift:31-35`, `ContentView.swift:3271-3275`). iOS notification permission is granted **per device**, not per Apple ID — a brand-new device that receives a synced car via §3.3 case 6 still needs its *own* first local pin-drop to trigger the rationale sheet and request permission on *that device*, or it will never schedule reminders there. Syncing this flag would silently suppress that prompt on every device except the first one ever used, which is the opposite of what the flag exists for. **Decided, argued explicitly per the task's ask — see below for the counter-case considered and rejected.** |
| `notificationsMutedKey` (W7 global mute) | `UserDefaults.standard`, unchanged | Per-device preference (e.g. Kevin mutes his iPad, keeps his phone loud). Forcing it to follow the car would surprise a user who muted one device on purpose. |
| `ReminderOffsets` (FT-6 preset toggles — 15min/30min/1hr/2hr/night-before) | `UserDefaults.standard`, unchanged | Same reasoning — per-device reminder cadence, not a property of the car. |
| `notificationRationaleShownKey`, `driveModeBackgroundNoteShownKey`, `parkingGuidePromptShownKey` | `UserDefaults.standard`, unchanged | One-time device-local UX-shown flags, entirely outside `ParkPinService`'s storage surface. Named here only to confirm scope: this feature touches nothing in `Constants.swift`. |

**The counter-case for syncing `hasEverParkedKey`, considered and rejected:** one could argue it
should sync so a returning user's *second* device doesn't show the rationale sheet at all, on the
theory that "they've already seen it once." Rejected because the rationale sheet's job is to get
notification **permission granted on this specific device** — showing it once globally would leave
every device after the first with reminders silently never scheduled (the `getNotificationSettings`
guard in `NotificationScheduler.schedule()` fails closed if permission was never requested) and no
prompt ever offered to fix it. Device-local is the correct choice, not just the conservative one.

**What *is* synced and why that's the right line:** the car's location, detected block, and the
per-pin `notifyOnRestriction` toggle — these describe the parking session itself, not a device
preference. Whether a specific device *acts* on `notifyOnRestriction` (schedules a local notification
for it) is still gated per-device by that device's own mute state, offsets, and permission grant
(§3.5) — sync carries *intent*, each device applies its *own* local policy on top.

### 3.5 The notification-interaction trace (the subtlest part, traced against real code)

Today, exactly two things drive scheduling: `ContentView.confirmPinDrop(result:)`
(`ContentView.swift:3300-3321`) captures `previousCarID = parkPinService.parkedCar?.id` **before**
calling `save()`, because `save()` fires `pinDropped` **synchronously on the main thread**
(`ParkPinService.swift:64-83`), which `ContentView`'s `.onReceive(parkPinService.pinDropped)`
(`ContentView.swift:778`) turns into a call to
`NotificationScheduler.shared.cancelAllThenSchedule(for:oldCarID:...)` via `handlePinDropped(_:)`
(`ContentView.swift:3279-3295`).

**The risk this spec exists to prevent:** if a remote-arrived car update were pushed through that
same `save()` → `pinDropped` path (the obvious naive implementation — "just call save() with the
merged car"), it would also:
- Fire `firstPinDropped` if `hasEverParkedKey` happens to be unset on this device (§3.3 case 6, a
  brand-new device) — incorrectly showing the W6 permission-rationale sheet as a reaction to a sync
  event the user didn't initiate on this device, not their own first pin drop.
- Fire `pinDropped`, which is *also* what W7.5 subscribes to for the "Parking until when?" auto-fire
  prompt (per the W8.5d changelog row, `pinDropped` firing today auto-opens `.parkUntil` in the
  arrival-confirm path). A remote arrival auto-opening a sheet on a device the user isn't looking at
  right now, or interrupting one they are, is exactly the double-schedule/orphan-reminder failure
  class the task named.
- Use `previousCarID` from `ContentView`'s local-drop-only bookkeeping, which is never updated by a
  remote path — so the "cancel the old car's notifications" step would target a stale or wrong ID.

**The fix: a third, distinct publisher — `remoteCarChanged` — that only `applyRemoteChange()` fires,
never `save()`/`clearPin()`.**

```swift
// ParkPinService.swift — new publisher, alongside firstPinDropped/pinDropped
let remoteCarChanged = PassthroughSubject<(newCar: ParkedCar?, oldCarID: UUID?), Never>()
```

```swift
// ContentView.swift — new .onReceive, parallel to the existing pinDropped one
.onReceive(parkPinService.remoteCarChanged) { newCar, oldCarID in
    handleRemoteCarChanged(newCar: newCar, oldCarID: oldCarID)
}

private func handleRemoteCarChanged(newCar: ParkedCar?, oldCarID: UUID?) {
    if let newCar {
        NotificationScheduler.shared.cancelAllThenSchedule(
            for: newCar, oldCarID: oldCarID,
            loadedSegments: tileLoader.segments, engine: engine
        )
    } else if let oldCarID {
        NotificationScheduler.shared.cancelAll(forUUID: oldCarID)   // new method, §3.7
    }
    previousCarID = newCar?.id   // keep this in sync so a SUBSEQUENT local drop still
                                  // computes its own "old ID" against current reality
    // §3.3.1 — dismiss a now-stale ParkedCarDetailView
    if case .parkedCarDetail(let shown) = activeSheet, shown.id == oldCarID {
        activeSheet = dismissTargetOutsideBrowseNav
    }
    // Mirror the existing onClearPin cleanup when the referenced car is gone.
    if newCar == nil, parkUntilMode {
        parkUntilMode = false
        parkUntilTarget = nil
        rebuildOverlays(at: .nowET)
    }
    // Deliberately does NOT set activeSheet = .notificationRationale or .parkUntil,
    // and does NOT touch hasEverParkedKey. Those are local-drop-only, by design.
}
```

**Why scheduling still happens on the receiving device, deliberately (§6 OQ-4 flags the alternative):**
`NotificationScheduler.schedule()` already fails closed per-device — it checks the local mute flag,
the per-pin `notifyOnRestriction`, and (inside the `getNotificationSettings` callback) whether this
device has ever been granted permission at all (`ParkPinService.swift`/`NotificationScheduler.swift:
122-124`). Calling `cancelAllThenSchedule` unconditionally on a remote arrival costs nothing on a
device that was never granted permission (silent no-op) and correctly reminds the user on every
device where they *did* grant it — which matches "remind me wherever I'll see it." This is a real
product choice, not a mechanical default; see §6 OQ-4 for the case against it.

**Main-actor / threading note, traced from the file's own doc comment:**
`ParkPinService.swift:10-11` already documents that `save()`/`clearPin()` must run on the main
thread because `UserDefaults` writes off-main can drop intermittently. `NSUbiquitousKeyValueStore`
carries the same requirement for its own reasons: `didChangeExternallyNotification` is **not
guaranteed to be delivered on the main thread** when the change is genuinely external (as opposed to
a same-process `synchronize()` echo). The fix is mechanical and cheap — register the observer with
an explicit main queue rather than hopping manually inside the handler:

```swift
NotificationCenter.default.addObserver(
    forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
    object: nil, queue: .main
) { [weak self] note in
    self?.applyRemoteChange(reason: note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int)
}
```

`ParkPinService` itself is `@Observable final class`, not `@MainActor`-annotated (unchanged from
today) — the `queue: .main` on the observer is what guarantees `parkedCar` is only ever mutated on
main, consistent with the file's existing invariant rather than adding a new one.

### 3.6 Migration from `UserDefaults`

**The standing project guidance changed and this is exactly the case it changed for.**
`docs/open-items.md`'s 2026-08-20 entry: *"Migration shims are no longer hypothetical. The old
'don't bother, Kevin's the only user' advice was correct then; re-evaluate per change now rather than
defaulting either way."* This one matters: skipping migration means every existing external
TestFlight user's currently-parked car silently vanishes on their next update — a real, if small
(single-field), data loss for real strangers.

**The migration is not a separate code path from the merge logic — it's the SAME code path, applied
once.** On `load()`, if a legacy `UserDefaults.standard` car exists (key `wepark_parked_car`,
unchanged from W5), it's decoded as a plain `ParkedCar` (the pre-envelope format — this key was never
touched by this feature, it just stops being read after this one-time pass) and wrapped into a
synthetic `.parked` envelope with `updatedAt = legacyCar.parkedAt`. That synthetic envelope is run
through the exact same "compare `updatedAt`, later wins" function used for every ordinary remote
update (§3.3 case 8) — there is no special "legacy always wins" or "cloud always wins" branch to get
wrong. Whichever wins becomes both `parkedCar` and (if the legacy one won) the freshly-written store
value. The legacy `UserDefaults` key is removed once, regardless of which side won — migration is
a one-time event, not a standing dual-read.

```swift
func load() {
    cloudStore.synchronize()   // best-effort freshness hint only

    let remote: SyncedCarEnvelope? = cloudStore.data(forKey: syncedStateKey)
        .flatMap { try? JSONDecoder().decode(SyncedCarEnvelope.self, from: $0) }

    if let legacyData = defaults.data(forKey: legacyStorageKey),
       let legacyCar = try? JSONDecoder().decode(ParkedCar.self, from: legacyData) {
        let legacy = SyncedCarEnvelope(kind: .parked, updatedAt: legacyCar.parkedAt, car: legacyCar)
        let winner = (remote.map { $0.updatedAt > legacy.updatedAt } ?? false) ? remote! : legacy
        apply(winner)
        if winner.updatedAt == legacy.updatedAt,
           let data = try? JSONEncoder().encode(winner) {
            cloudStore.set(data, forKey: syncedStateKey)   // legacy won — publish it
        }
        defaults.removeObject(forKey: legacyStorageKey)     // one-time, either way
    } else {
        apply(remote)   // nil is a valid "no car" state — case 5/6
    }

    startObservingRemoteChanges()
}
```

### 3.7 Testability seam — most of this IS unit-testable

The reason `docs/build-18-sizing.md` flagged this as "untestable in the sandbox" is real for the
*delivery mechanism* (does iCloud actually propagate, how fast, across a real account) — but the
**merge/tombstone/migration logic**, which is the actual hard part, does not need real iCloud to
verify. Mirror the pattern `NotificationScheduler.swift` already uses for
`UNUserNotificationCenterProtocol` (`NotificationScheduler.swift:515-524`):

```swift
protocol UbiquitousKeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    @discardableResult func synchronize() -> Bool
}
extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {}
```

`ParkPinService` takes an injectable `cloudStore: UbiquitousKeyValueStoring = NSUbiquitousKeyValueStore.default`
(production default unchanged) and `defaults: UserDefaults = .standard`, exactly mirroring
`NotificationScheduler(center:)`'s existing test-injection pattern. `applyRemoteChange()` is
`internal`, not `private` — a directly callable test entry point, exactly like `scheduleForTest`
already bypasses the settings-check chrome around `enqueuePresets` for the same reason (tests can't
trigger a real `didChangeExternallyNotification` any more than they can grant real notification
permission). A `MockUbiquitousStore` (in-memory dictionary) lets a test seed an arbitrary remote
envelope, call `applyRemoteChange()` directly, and assert on `parkedCar`/`remoteCarChanged` output —
no real device, no real iCloud account, no simulator quirks. **This is what makes §5's AC-6 through
AC-16 CI-verifiable rather than promises.**

**What remains genuinely untestable without real hardware, stated honestly (§7):** whether iCloud
actually delivers a write to a second device, how long it takes, whether `AccountChange` behaves in
practice the way Apple's docs describe, and whether the newly-added entitlement is correctly
provisioned end to end (App ID capability → provisioning profile → signed build). All four require
two physical devices signed into the same Apple ID.

---

## 4. Work streams

**No parallel iOS streams recommended for this feature.** The envelope model, the `ParkPinService`
rewrite, the `NotificationScheduler` addition, and the `ContentView` wiring form a strict dependency
chain (each consumes the previous step's interface) — splitting them across concurrent engineers
would mean one waits on the other's interface anyway. This differs from `docs/build-18-sizing.md`
§7's framing, which is about *this feature relative to other build-18 items* (there, correctly, "fully
disjoint" — `ParkPinService.swift` isn't touched by FT-2 or `open_spot`). Within this feature itself,
serialize.

| Stream | Owner | Depends on | What |
|---|---|---|---|
| **0 — iCloud capability** | Kevin (Mac, Xcode) | Nothing — can happen anytime before Stream 3's device test, ideally before Stream 1 so the entitlement exists when code lands | Xcode → target → Signing & Capabilities → + Capability → iCloud → check "Key-value storage." Commit the resulting `.entitlements` file. ~15 min, one-time. |
| **1 — Storage layer** | `@ios-engineer` | Stream 0 not required to *write* this code, only to run it on-device | `SyncedCarEnvelope.swift` (new), `ParkPinService.swift` rewrite: injectable store seam, `save()`/`clearPin()`/`updateNotifyOnRestriction()` retargeted to the envelope+cloud store, `load()` migration logic (§3.6), `applyRemoteChange()` + `remoteCarChanged` publisher (§3.5), observer registration (§3.5's threading note). Baseline round-trip tests for the *unchanged* local behavior (no existing coverage — §3, file list) plus new merge/tombstone/migration/quota tests via the mock store (§3.7). **~1–1.5 sessions.** |
| **2 — Scheduler + ContentView wiring** | `@ios-engineer`, same engineer for context continuity | Stream 1 (consumes `remoteCarChanged`) | `NotificationScheduler.cancelAll(forUUID:)` (small, mirrors existing `cancelAll(for:)`). `ContentView.swift`: new `.onReceive(remoteCarChanged)`, `handleRemoteCarChanged(newCar:oldCarID:)` (§3.5), generalize `previousCarID` bookkeeping so it stays correct across local AND remote paths, stale-sheet-dismiss branch (§3.3.1), Park-Until-filter cleanup on remote clear. Tests: mock-driven assertions that `remoteCarChanged` never triggers `.notificationRationale`/`.parkUntil` and that `firstPinDropped`/`pinDropped` never fire from `applyRemoteChange()`. **~0.5–1 session.** |
| **3 — Device verification** | Kevin, two physical devices, same Apple ID | Streams 0–2 merged and archived | The two-device gate — §7. Not skippable, not simulatable. **~0.5–1.5 sessions of Kevin's time**, plus whatever follow-up round the findings require (see §8 sizing). |
| **QA** | `@qa-verifier` | Streams 1–2 | Code review + verify the unit-test suite actually exercises the state matrix (§3.3), not just the happy path. Explicitly **cannot** sign off on cross-device delivery — says so in the report rather than implying coverage it doesn't have. |

No `@backend-data` stream (no server component). No `@pwa-maintainer` stream (PWA's `localStorage`
car pin is untouched, maintenance mode). No `@designer` stream (no new UI surface, per Scope §2).

---

## 5. Acceptance criteria

**Simulator/unit-testable (Streams 1–2, QA):**

1. `ParkPinService` reads/writes `UserDefaults.standard` only via the legacy migration path in
   `load()` — no other method touches it.
2. Fresh install, empty cloud store, no legacy blob → no car on launch. Unchanged from today.
3. `save()` still fires `firstPinDropped` exactly once per install (`hasEverParkedKey` semantics
   unchanged) and `pinDropped` on every save, exactly as today — regression, not a rewrite of local
   behavior.
4. `save()` writes a `.parked` envelope with `updatedAt == car.parkedAt`.
5. `clearPin()` writes a `.cleared` tombstone envelope (not a removed/absent key) with a fresh
   `updatedAt`.
6. Migration: legacy-only device (empty cloud store) → legacy car becomes the store's first envelope
   unchanged in content; legacy `UserDefaults` key removed after.
7. Migration + conflict: legacy car present AND a different envelope already in the cloud store →
   resolved by `updatedAt` comparison only, verified both directions (legacy newer wins, remote newer
   wins) — no origin-based special case.
8. `hasEverParkedKey` is never read or written by `applyRemoteChange()`, `load()`'s remote-only path,
   or the migration path — only by `save()`. Verified by a test that applies a remote change to a
   device with `hasEverParkedKey` unset and asserts it's still unset afterward.
9. A remote envelope with `updatedAt <=` the currently-applied `updatedAt` is a no-op — `parkedCar`,
   `currentUpdatedAt`, and all three publishers stay untouched.
10. A remote envelope with a strictly greater `updatedAt` and `kind == .parked` updates `parkedCar`
    and fires `remoteCarChanged` with the correct `(newCar, oldCarID)` pair.
11. A remote envelope with a strictly greater `updatedAt` and `kind == .cleared` sets `parkedCar` to
    nil and fires `remoteCarChanged` with `(nil, oldCarID)`.
12. `firstPinDropped` and `pinDropped` **never** fire as a result of `applyRemoteChange()` — direct
    test subscribing to all three publishers, applying a remote change, asserting events on
    `remoteCarChanged` only.
13. `activeSheet` is never set to `.notificationRationale` or `.parkUntil` as a result of
    `handleRemoteCarChanged`.
14. If `activeSheet == .parkedCarDetail(car)` and a remote change replaces/clears that car's `id`,
    the sheet dismisses (per §0.3's ruling).
15. On remote-car-arrival with a non-nil new car, `NotificationScheduler.cancelAllThenSchedule` is
    invoked with the correct `oldCarID`; on remote-clear, `cancelAll(forUUID:)` is invoked with the
    correct id and nothing new is scheduled.
16. `updateNotifyOnRestriction(_:)` writes an envelope with a bumped `updatedAt` even though
    `car.parkedAt` is unchanged — verified by applying the resulting envelope as a "remote" update to
    a second `ParkPinService` instance seeded with the pre-toggle car and confirming it adopts the new
    `notifyOnRestriction` value (this is the concrete test for §0.1's ruling).
17. `QuotaViolationChange` is handled without crash and without a partial/corrupt write (synthesized
    via the `reason` parameter, not a real quota event).
18. A representative `SyncedCarEnvelope` encodes to well under 2 KB (canary against quota risk, not a
    hard product requirement).
19. Full existing suite (830 tests as of the 2026-08-24 changelog entry) plus all new tests pass.

**Device-only (Stream 3, Kevin, two physical devices, same Apple ID) — cannot be verified any other
way, stated plainly rather than implied as covered by the above:**

20. Park on device A → car appears on device B within some observed real-world window (no fixed SLA
    — document what's actually observed; this is inherently non-deterministic per §3.1).
21. Clear on device B → device A's pending local notifications for that car are cancelled and its pin
    disappears, without the user touching device A.
22. A third, fresh-install device already signed into the same Apple ID sees the currently-parked car
    on first launch, with no action taken on that device (§3.3 case 6) — and its own `hasEverParkedKey`
    remains unset (its first *local* pin drop still shows the W6 rationale sheet later).
23. No double-fire of the W6 rationale sheet or the W7.5 Park-Until auto-prompt on the receiving
    device when a car syncs in from another device.
24. The iCloud capability/entitlement is present and functional in an actual archived/TestFlight
    build, not just a debug build signed with a development team — verify sync works from a
    TestFlight-distributed build, not only Xcode-run-on-device.

---

## 6. Open decisions

(Restated from §0 with full context, plus one more found while writing this section.)

> **✅ CONFIRMED by Kevin 2026-08-27 — "yes to all three" (OQ-1/2/3, as recommended below).**
> Recorded here because QA (docs/qa/pr91-icloud-parked-car-sync.md) flagged the missing paper trail
> as merge-gating. The code already implemented these recommendations; this note closes the gap.

- **OQ-1 (§0.1):** Use envelope-level `updatedAt` (bumped on every write) as the merge comparator,
  rather than raw `ParkedCar.parkedAt`. Recommendation: yes — it's a strict refinement of the ruling
  that also fixes toggle-edit propagation, not a reversal of it.
- **OQ-2 (§0.2):** `AccountChange` treated identically to a normal remote update. Recommendation:
  yes, for simplicity and because multiple Apple IDs on one device running this app is a narrow edge
  case — but this is a real (if narrow) product decision about a different-person's-data-appearing
  scenario, not purely mechanical, so it's listed rather than assumed.
- **OQ-3 (§0.3):** Dismiss (not live-refresh) `ParkedCarDetailView` on a remote change to the shown
  car. Recommendation: dismiss — simplest, matches the existing `onDismiss` pattern, and a live
  refresh is a small follow-up if ever wanted.
- **OQ-4 (§3.5):** Should a receiving device schedule local reminders for a car it didn't park,
  purely because it has notification permission? Recommendation: yes (a user reasonably wants to be
  reminded wherever they'll see it, and it's a silent no-op on devices without permission) — but this
  means an iPad that's never left the house could buzz "move your car" for a car parked from the
  owner's phone. If Kevin wants reminders to stay tied to "the device that parked it" specifically,
  that's a different, larger design (would need to track an "authoring device" concept this spec
  doesn't have) — flagging so the simpler default isn't assumed without a look.

---

## 7. The verification gate, stated honestly

**Neither a simulator nor a single device can prove cross-device sync.** This is the same shape of
problem `HANDOFF.md`'s 2026-08-22 entry describes for FT-20's bottom-sheet detent — six build-and-
smoke rounds where a single-device check kept looking locally correct. The difference here is that
§3.7's testability seam means the *logic* most likely to be wrong (the merge math, the tombstone
handling, the migration branch) is fully covered by unit tests **before** any device is involved —
narrower residual risk than FT-20 had, because FT-20's bug was in exactly the kind of runtime-only
SwiftUI layout behavior that has no unit-testable seam. What's left for hardware is genuinely only the
*delivery mechanism*: does iCloud actually propagate a write, how fast, does `AccountChange` behave as
documented, is the entitlement correctly provisioned in a real archived build. All four require **two
real devices signed into the same Apple ID** — AC-20 through AC-24.

**If Kevin does not have a second device available:** what can still be verified — the entire unit
suite (AC-1–19), a single-device smoke (park, clear, force-quit, relaunch, confirm the car persists —
this exercises the storage swap without exercising sync itself), and a manual check that
`didChangeExternallyNotification` fires at all (achievable solo by editing the value directly via
`iCloud.com`'s developer tools or a second build under a *different* bundle ID sharing the same
ubiquity container — an imperfect proxy, not equivalent to a real second device, but better than
nothing). **What cannot be verified without a second device:** whether the feature actually delivers
its core promise (§1's user story). The residual risk of shipping without AC-20–24 is real and
specific: a broken sync path would ship invisibly, look identical to "no iCloud account" in every
single-device check, and only surface when an external user with two devices notices their car isn't
appearing — silently failing the exact scenario this feature exists to fix, discovered by a stranger
instead of by Kevin. **Recommend not shipping past Stream 2 without at minimum one round on two real
devices**, even borrowed ones, given how load-bearing and how untestable-otherwise this specific gate
is.

---

## 8. Sizing

`docs/build-18-sizing.md` §2 priced this at **~2.5–4 sessions total** (0.5 mechanical swap + 1.5–2.5
conflict-policy design/implementation + 0.5–1 QA + one likely follow-up round). This spec's own
estimate, now that the design is fully worked out rather than sketched, and folding in two things
that sizing pass didn't have visibility into (this doc's own research):

- **The iCloud entitlement doesn't exist yet** (§0, §4 Stream 0) — a small but real, Mac-only,
  one-time setup step with its own failure mode (silent non-sync if misconfigured) that needs its own
  verification pass, not assumed free.
- **`ParkPinService` has zero existing test coverage** (§3, §4 Stream 1) — this rewrite has to build
  the baseline regression net for the *unchanged* local behavior at the same time as the new logic,
  which build-18-sizing's estimate didn't itemize separately.

**Revised: Stream 1 ~1–1.5 sessions, Stream 2 ~0.5–1 session, Stream 0 ~0.25 session (Kevin), QA
~0.5 session. Engineering + QA subtotal: ~2.25–3.25 sessions** — narrower than build-18-sizing's
range on the code-writing side specifically because §3.7's testability seam de-risks the merge logic
before any device is touched.

**Then Stream 3, the device-verification round, calibrated against this project's own most recent
lesson rather than treated as a rounding error:** FT-20's own "honest" estimate (4.5–6.5 sessions,
with an explicit budgeted follow-up round already built in) still landed at roughly **double** in
practice, driven entirely by on-device iteration cost on a bug class a simulator couldn't catch. This
feature's untested residual (§7) is smaller in surface area than FT-20's UI-layout bug class was, but
it is the **same shape** — a behavior that can look fine everywhere except two real devices, on real
account state, with real timing. Budget at least one full follow-up round after the first two-device
test, not zero.

**Total, realistic: ~4–6 sessions** (2.25–3.25 engineering/QA + 0.25 Kevin/Xcode setup + 1.5–2.5
device-verification-and-fix rounds), a touch above build-18-sizing's 2.5–4 ceiling — the delta is the
entitlement step and the explicit fix-round budget, both concrete findings from writing this spec, not
padding.

---

## 9. Out-of-scope follow-ups

- **No user-visible "synced from your other device" indicator.** Would be a nice trust signal (the
  user currently has zero way to tell the car they're looking at arrived via sync vs. was parked
  locally) but Kevin explicitly wants zero new UI for this feature. Worth a one-line settings-screen
  mention post-ship if support questions come in ("why does my car show up on my other phone?").
- **No settings toggle to disable cross-device sync.** A user who shares an Apple ID with someone else
  (not Family Sharing — `NSUbiquitousKeyValueStore` is per-Apple-ID, not shared across a Family
  Sharing group by default, which narrows this concern considerably) and doesn't want their parked
  location visible on a shared device has no opt-out. Narrow enough not to block this spec; worth
  remembering if it ever comes up.
- **No live-refresh of `ParkedCarDetailView` on a remote change** (§0.3/§6 OQ-3) — dismiss-only for
  now. A follow-up could make the sheet observe `parkedCar` directly and refresh in place instead.
- **No "authoring device" concept** (§6 OQ-4) — if Kevin later wants reminders to stay tied to
  whichever device actually parked the car, that's a materially different, larger design than this
  spec builds. Not started here.
- **No CloudKit migration path considered.** `NSUbiquitousKeyValueStore` is the right tool for a
  single small blob with no query needs; if this feature ever grows into "parking history across
  devices" or anything requiring more than 1 MB / structured querying, that's a CloudKit (or backend)
  rebuild, not an extension of this one. Named so nobody tries to bolt history onto this store later.
