# FT-2: Delete Own Community Pin (Accidental Report)

**Spec status:** Draft — awaiting Kevin sign-off on open decisions before code starts.
**Decision locked:** HARD DELETE with a confirmation dialog.
**Target build:** NOT TF2. Next build after TF2.
**Codebases touched:** iOS only. No PWA changes. No new Supabase migrations required (see Backend section).
**Spec replaces:** none — this is a new feature.

---

## Open Decisions (Read First)

**OQ-1 — SCHEMA VERIFICATION REQUIRED (Kevin, ~2 min).**
`02-pins-schema.sql` already contains `pins_delete_own` RLS policy (lines 157-159) and the `votes` FK with `ON DELETE CASCADE` (line 166). Kevin applied this schema to production (Supabase project `jiispshyqerscdoferaw`) during the Tier 1 milestone (HANDOFF.md Changelog 2026-06-02, line 290). Before any iOS code starts, Kevin must verify whether both already exist in prod. Run the two verification queries in §3.1 below. If both return the expected rows, NO schema change is needed. If either is missing, apply the idempotent SQL in §3.2.

**OQ-2 — Which pin types are deletable?**
The spec as described targets crowd-sourced ephemeral pins (`enforcement_active`, `sweeper_passed`, `broken_meter` — the types the user can report via patrol mode). Should `filming` and `special_event` open-data pins (seeded by the ingest pipeline, `author_id = null`) show a delete button to anyone? No — they should not; the delete button is only meaningful when `isOwnPin == true`, and open-data pins have `author_id = null`, so `isOwnPin` is `false` by construction. No additional guard is required. Calling this out explicitly so the engineer does not add a separate `source == .crowd` check.

**OQ-3 — Toast copy.**
The spec recommends "Report deleted." Is that the right copy? Kevin should confirm or override. The copy appears in one call site: `ToastService.shared.show(message: "Report deleted.")`.

---

## 1. Problem and User Story

A user long-presses the map, drops an `enforcement_active` or `sweeper_passed` pin, and immediately realizes they tapped the wrong spot or the wrong type. Today there is no recovery path. The pin lives for 30 minutes and is visible to all other users in the area. The user has to wait it out.

**User story:** As a user who just reported a community pin by accident, I want to be able to delete my own report immediately so that I do not mislead other users with bad information.

**Why now:** The write path (patrol mode report sheet, Tier 3 sub-PR #2) shipped in the same build cycle. Accidental reports are now possible. The delete escape hatch should be present in the first release that exposes reporting.

**Current state in the UI:** `PinDetailSheet.swift` shows `ReactionsRow` for own pins but disables both "Still there?" and "Gone" vote buttons when `isOwnPin == true` (A1 guard, `PinDetailSheet.swift` lines 335-358). The user sees a greyed-out reactions row and has no other action available on their own pin. FT-2 replaces that dead end with a delete action.

---

## 2. Scope

### In

- iOS only: `CommunityPinService.deleteCrowdPin(id:)` method + `PinDetailSheet` delete UI.
- Hard delete of the pin row. Votes cascade automatically (see §3).
- Shown only when `isOwnPin == true` (the existing `ReactionsRow.isOwnPin` logic).
- Confirmation dialog before delete executes.
- Optimistic local removal from `visiblePins` on confirm, before the network call completes.
- Toast confirmation via `ToastService.shared` after sheet dismissal.
- Unit tests: `deleteCrowdPin` method behavior + UI guard (own vs. others' pin).

### Out (explicitly deferred)

- Admin/moderator delete (different auth requirement, future).
- Soft delete / `resolved_at` path (Kevin locked HARD DELETE).
- Edit/correction flow (separate feature, not in scope).
- PWA (maintenance mode).
- Android (not started).
- Undo after delete (no undo; deletion is instant and final).

---

## 3. Backend (Supabase RLS)

### 3.1 Verification queries (Kevin runs in SQL Editor — takes ~30 seconds)

**Verify the RLS policy exists:**

```sql
select policyname, cmd, qual
from pg_policies
where schemaname = 'public'
  and tablename = 'pins'
  and policyname = 'pins_delete_own';
```

Expected result: one row with `cmd = 'DELETE'` and `qual` containing `auth.uid() = author_id`.

**Verify votes cascade:**

```sql
select
  tc.constraint_name,
  rc.delete_rule
from information_schema.table_constraints tc
join information_schema.referential_constraints rc
  on rc.constraint_name = tc.constraint_name
where tc.table_name = 'votes'
  and tc.constraint_type = 'FOREIGN KEY';
```

Expected result: the FK referencing `pins(id)` shows `delete_rule = 'CASCADE'`.

### 3.2 SQL to apply (only if verification queries in §3.1 show missing rows)

Both statements are idempotent (use `drop policy if exists` / the FK is already defined with `on delete cascade` in the `create table` DDL). If the schema was applied from `02-pins-schema.sql` intact, nothing below is needed. This is provided as a safety net for a partially-applied schema.

**Apply in the SQL Editor — run as a single block:**

```sql
-- Step 1: Add ON DELETE CASCADE to votes.pin_id FK (only if missing).
-- WARNING: this requires dropping and re-adding the FK constraint.
-- If the verification query above shows delete_rule = 'CASCADE', SKIP THIS STEP.

alter table public.votes
  drop constraint if exists votes_pin_id_fkey;

alter table public.votes
  add constraint votes_pin_id_fkey
    foreign key (pin_id)
    references public.pins(id)
    on delete cascade;

-- Step 2: RLS delete policy on pins (idempotent — drop-if-exists then re-create).
-- Style matches existing policies in 02-pins-schema.sql (drop policy if exists → create policy).
-- Role: no explicit TO clause — applies to all non-superuser roles (same pattern as
-- pins_select_public, pins_insert_crowd, pins_update_own in 02-pins-schema.sql lines 133-154).
-- auth.uid() evaluates to the JWT's sub claim at query time.
-- Anonymous callers: auth.uid() returns null, so the USING clause is false — anon cannot delete.

drop policy if exists pins_delete_own on public.pins;
create policy pins_delete_own on public.pins
  for delete using (auth.uid() = author_id);
```

**Verification after apply:**

Re-run the queries in §3.1. Both should now return the expected rows. Then verify no existing data is corrupted: `select count(*) from public.votes;` should return the same count as before (the FK change does not cascade-delete anything unless a pin is deleted).

### 3.3 Cascade behavior — correctness rationale

The `votes` table has `pin_id uuid not null references public.pins(id) on delete cascade` (02-pins-schema.sql line 166). When a pin row is hard-deleted, Postgres cascades the delete to all `votes` rows with that `pin_id`. This is the cleanest option: no client-side pre-delete of votes, no orphan rows, atomic. The `refresh_pin_vote_counts` trigger fires on vote deletion but the pin row will already be gone from the perspective of the UPDATE it attempts — that UPDATE is a no-op (zero rows matched), not an error. No additional trigger work is needed.

### 3.4 RLS design notes

- The policy uses no `to` role clause, consistent with `pins_insert_crowd` and `pins_update_own` in the schema. In Supabase's default setup, both `anon` and `authenticated` roles are present; the `USING (auth.uid() = author_id)` clause is false for `anon` (auth.uid() = null) and for any authenticated user who is not the author.
- `author_id` is set to the anon user's UUID at insert time (see `insertCrowdPin` in `CommunityPinService.swift` line 701: `"author_id": userId.uuidString`). The same UUID is what `auth.uid()` returns from the JWT on subsequent calls from the same device. The RLS check is therefore a direct UUID equality on a single column — no join, fast.
- Open-data pins have `author_id = null` (seeded via service-role key per the schema comment at line 55). `null = auth.uid()` is always false in Postgres, so the delete policy correctly rejects any attempt to delete seeded pins.

---

## 4. iOS Implementation

### 4.1 `CommunityPinService.deleteCrowdPin(id:)` — new method

**Location:** `ios/WePark/WePark/Services/CommunityPinService.swift`, as a new `// MARK: - Write path: Delete own pin` section after `callExtendPinExpiry`.

**Signature:**

```
func deleteCrowdPin(id: UUID) async throws
```

**Behavior spec (not implementation code):**

1. Auth check: guard `authService != nil`, `validAccessToken()` returns a non-nil JWT, and `currentUserId != nil`. Throw `CommunityPinWriteError.notAuthenticated` on any failure. This mirrors the guard pattern in `insertCrowdPin` (lines 674-679) and `upsertVote` (lines 758-764).

2. Optimistic local removal: before the network call, call `visiblePins.removeAll { $0.id == id }`. This makes the map update immediately on the user's device. If the network call subsequently fails, the pin will re-appear on the next periodic refresh (8s timer) or region-change re-fetch.

3. Network call: issue a PostgREST DELETE request via `buildAuthenticatedRequest(path:method:jwt:body:extraHeaders:)`:
   - `path`: `"rest/v1/pins"`
   - `method`: `"DELETE"`
   - `jwt`: the token from `validAccessToken()`
   - `body`: `nil` (DELETE has no body)
   - `extraHeaders`: `["Prefer": "return=minimal"]`
   - URL filter: the pin ID is passed as a PostgREST query parameter, not in the path. The constructed URL should have `?id=eq.<uuid-string>` appended. Use `URLComponents` to append the query item to `supabaseURL.appendingPathComponent("rest/v1/pins")`, exactly as the existing request builders do for bounding-box filters (see `buildOpenDataRequest` at lines 436-470 for the `URLComponents` pattern).

4. Response handling:
   - HTTP 204 (No Content with `Prefer: return=minimal`) is success. Treat any `(200..<300)` status as success, consistent with the existing write methods.
   - HTTP 403: the RLS policy rejected the delete. The caller is not the author. Throw `CommunityPinWriteError.httpError(statusCode: 403)`. In practice this should not happen if the UI guard is correct, but the server-side check is the authoritative gate.
   - HTTP 404: pin was already deleted (possibly by the periodic refresh having already removed it, or a race). Treat as success — the desired end state (pin absent) is achieved. Do NOT throw.
   - Any other non-2xx: throw `CommunityPinWriteError.httpError(statusCode:)`.
   - Network error: propagate the URLSession error (the caller's `do/catch` in the UI handles it).

5. Realtime reconciliation: after a successful delete, `mergeRealtimeChange` may receive a DELETE event from Supabase Realtime (if the WebSocket SDK path is ever activated). `mergeRealtimeChange` already handles `resolvedAt != nil` by calling `visiblePins.removeAll { $0.id == pin.id }` (lines 589-591). A hard-delete Realtime event (which would arrive as a DELETE record type, distinct from an UPDATE with resolvedAt set) would need to be handled by a future `mergeRealtimeDeletion(pinId:)` method — but that is the SDK activation path, not TF2 scope. For TF2's polling-based Realtime model: the optimistic removal (step 2) handles the immediate case; the periodic refresh will not return the deleted pin on subsequent polls because it no longer exists in the DB. No additional reconciliation code is required for the polling path. The spec calls out the double-remove risk: if `mergeRealtimeChange` is called with a pin that already has `resolvedAt != nil` matching an already-removed pin ID, `removeAll` on an array that does not contain the ID is a no-op — no crash.

### 4.2 `PinDetailSheet` delete UI

**Location:** `ios/WePark/WePark/Views/PinDetailSheet.swift`

**Placement:** Replace the existing `ReactionsRow` content for own pins. Currently `ReactionsRow` shows greyed-out "Still there?" and "Gone" buttons when `isOwnPin == true`. The delete action replaces both buttons when `isOwnPin == true` — the vote buttons remain for non-own pins, unchanged.

**Conditional rendering:** The existing `if pin.lifespan == .ephemeral && pin.source == .crowd` block in `PinDetailSheet.body` (lines 55-64) wraps the `ReactionsRow`. The delete button should be injected into `ReactionsRow` directly: when `isOwnPin == true`, render the delete button instead of the two vote buttons. The section header ("Community Check") and confirm count badge are also not relevant for own pins — hide them when showing the delete UI.

**Delete button spec:**

- Label: `"I reported this by mistake"` (secondary copy) with a `trash` SF Symbol, or at minimum a prominent `"Delete Report"` label. The engineer should follow the existing `.buttonStyle(.bordered)` / `.tint` pattern used for the vote buttons. Use `.tint(.red)` to signal destructive action.
- Full-width, matching the existing vote button layout (`frame(maxWidth: .infinity)`).
- Minimum 44pt tap target (HIG, consistent with the vote buttons at `.padding(.vertical, 10)`).
- Accessibility label: `"Delete this report — tap to remove your accidental pin"`.

**Confirmation dialog:**

On button tap, do not call `deleteCrowdPin` immediately. Present a confirmation dialog using SwiftUI's `.confirmationDialog` modifier (or `.alert` — `.confirmationDialog` is preferred for destructive iOS actions; it renders as an action sheet on iPhone). The dialog spec:

- Title: `"Delete this report?"`
- Message: `"This will permanently remove your pin. This cannot be undone."`
- Destructive button: `"Delete"` (role: `.destructive`)
- Cancel button: default cancel (role: `.cancel`)

On "Delete" confirm:

1. Set `isLoading = true` (show `ProgressView` in place of the delete button).
2. Call `pinService.deleteCrowdPin(id: pin.id)` inside a `Task`.
3. On success: call `onDismiss()` to close the sheet, then `await MainActor.run { ToastService.shared.show(message: "Report deleted.") }`. The toast appears over the map after the sheet dismisses.
4. On failure (any error): set `isLoading = false`, set `errorMessage` to `"Couldn't delete — please try again."`. Do NOT dismiss the sheet on failure.

**State variables to add to `ReactionsRow`:**

- `@State private var showDeleteConfirmation: Bool = false` — drives the `.confirmationDialog` presentation.

**Invariants to preserve:**

- `CommunityPin.swift` is NOT modified (AC-D20 / AC-I2 from the existing spec). All logic lives in `PinDetailSheet.swift` and `CommunityPinService.swift`.
- No `Calendar.current` use.
- No force-unwraps.
- The non-own-pin vote buttons path is NOT changed. Own-pin guard is already tested; do not regress it.

### 4.3 `ContentView.swift` — no changes required

The sheet is dismissed via `onDismiss()` callback (already wired at `ActiveSheet.pinDetail` in `ContentView.sheetContent`, line 723-728). `ToastService.shared` is a singleton accessible without injection. No new `ActiveSheet` case is needed.

---

## 5. Edge Cases

**Pin already expired or removed when delete is tapped:**

The user may open `PinDetailSheet` on a live pin, wait 30 minutes, and then tap Delete after the pin has expired server-side. The PostgREST DELETE with `?id=eq.<uuid>` on a non-existent row returns HTTP 200 or 204 with zero rows affected (not a 404 — PostgREST treats "zero rows matched" as success on DELETE). Treat any `(200..<300)` response as success and dismiss the sheet normally. The client-side expiry filter in `clientSideFilter` would have already removed the pin from `visiblePins` on the next periodic refresh regardless.

**Delete while offline:**

The URLSession call will throw a `URLError` (e.g. `.notConnectedToInternet`). The `do/catch` in the UI handler catches this, sets `errorMessage`, and keeps the sheet open. The optimistic removal (step 2 of the service method) will have already removed the pin from `visiblePins`. If the user force-quits and returns, the next periodic refresh will re-fetch from the server — the pin will reappear if the delete did not go through. This is consistent with the existing optimistic-append behavior for `insertCrowdPin` (which can also "appear then disappear" if the insert fails server-side and the UI does not roll back). Acceptable for TF2.

**Double-tap (race on the confirm button):**

The `isLoading` state flag is set to `true` before the `Task` fires. The confirm button is gated by `isLoading` (the engineer should add `.disabled(isLoading)` to the delete button, consistent with the vote button's `isLoading` guard in the existing `ReactionsRow`). A second tap while `isLoading` is true is a no-op.

**Realtime DELETE event arriving after optimistic removal:**

As described in §4.1 step 5: `visiblePins.removeAll { $0.id == pin.id }` on an already-empty ID is a no-op. No crash.

**User taps delete on another user's pin (should be impossible via UI):**

The delete button only appears when `isOwnPin == true`. The server-side RLS policy `pins_delete_own` (`USING (auth.uid() = author_id)`) provides the authoritative backstop. Even if a bug introduced the delete button on a non-own pin, the server would return HTTP 403, the error path would show the error message, and the optimistic removal would reverse on the next periodic refresh.

---

## 6. Work Streams

All work is in a single PR. There is no parallelization benefit here — the iOS service method must exist before the UI can reference it, and the backend verification is Kevin's manual step before code starts.

| Stream | Owner | Depends on | Can parallelize? |
|---|---|---|---|
| S1: Kevin verifies/applies schema in §3.1/3.2 | Kevin (manual dashboard step) | Nothing | Must complete before PR is merged to prod |
| S2: `deleteCrowdPin(id:)` in `CommunityPinService.swift` | `@ios-engineer` | S1 verification result (spec is self-contained) | Can start immediately |
| S3: Delete UI in `PinDetailSheet.swift` | `@ios-engineer` | S2 (calls `deleteCrowdPin`) | Sequential after S2 |
| S4: Unit tests | `@ios-engineer` | S2 + S3 | Sequential after S3 |
| S5: QA verification | `@qa-verifier` | S4 merged | Sequential after S4 |

S1 does not block S2 from being written and tested — the unit tests mock the network layer (no live Supabase needed). S1 must be done before the PR is pushed to a branch that is smoke-tested against production.

---

## 7. Tests

**Pattern to follow:** `Tier3AuthReactionsTests.swift` for service-layer network mocking, `CommunityPinServiceTests.swift` for fixture-based state assertions. Both use `MockURLProtocol` / `AuthMockURLProtocol` with `nonisolated(unsafe) static var requestHandler`. The new tests should use the same `PinMockURLProtocol` or `AuthMockURLProtocol` pattern already established — do not create a new mock class.

**Test inventory (8 tests):**

**Service layer — `deleteCrowdPin`:**

1. `testDeleteCrowdPin_notAuthenticated_throws` — Arrange: `CommunityPinService` init'd with `authService = nil`. Act: `try await service.deleteCrowdPin(id: someUUID)`. Assert: throws `CommunityPinWriteError.notAuthenticated`.

2. `testDeleteCrowdPin_requestShape` — Arrange: authenticated service with a mock that captures the request. Act: `try await service.deleteCrowdPin(id: someUUID)`. Assert: `request.httpMethod == "DELETE"`, URL contains `rest/v1/pins`, URL query contains `id=eq.<uuid>`, `Authorization` header is present and starts with `"Bearer "`, `apikey` header equals the anon key.

3. `testDeleteCrowdPin_204_removesFromVisiblePins` — Arrange: service with a pin pre-injected via `inject(fixtures:)`, mock returns HTTP 204. Act: `try await service.deleteCrowdPin(id: pin.id)`. Assert: `service.visiblePins` does not contain a pin with that ID.

4. `testDeleteCrowdPin_404_treatedAsSuccess` — Arrange: mock returns HTTP 404. Act: `try await service.deleteCrowdPin(id: someUUID)`. Assert: does NOT throw.

5. `testDeleteCrowdPin_403_throwsHttpError` — Arrange: mock returns HTTP 403. Act/Assert: throws `CommunityPinWriteError.httpError(statusCode: 403)`.

6. `testDeleteCrowdPin_optimisticRemoval_beforeNetworkCall` — Arrange: service with a pre-injected pin, mock that introduces a small async delay before returning 204. Assert: `visiblePins` is empty immediately after `removeAll` fires (this is tricky to test directly — an alternative is to assert that `visiblePins` does NOT contain the pin after the `await` returns, since the optimistic removal is synchronous before the `try await` network call). Note: if the engineer judges this test redundant given test 3, it may be folded into test 3 with a comment.

**UI guard — `ReactionsRow`:**

7. `testReactionsRow_ownPin_showsDeleteButton_notVoteButtons` — This is a logic test, not a SwiftUI rendering test. Assert the `isOwnPin` computed property returns `true` when `pin.authorId == authService.currentUserId`, and `false` otherwise. The existing tests at `Tier3AuthReactionsTests.swift` lines 11-13 (`testOwnPinGuard_sameId_isOwnPin_true`, `testOwnPinGuard_differentId_isOwnPin_false`, `testOwnPinGuard_nilAuthorId_isOwnPin_false`) already cover the guard logic. The engineer should verify these still pass after the `ReactionsRow` changes and add a new test only if the `isOwnPin` logic is modified.

8. `testDeleteCrowdPin_networkError_doesNotDismiss` — Arrange: mock throws `URLError(.notConnectedToInternet)`. Act: call `deleteCrowdPin`. Assert: throws (the UI's `catch` path is tested by the service throwing; UI behavior is covered by the smoke gate).

**Test file:** Create `ios/WePark/WeParkTests/FT2DeleteOwnPinTests.swift`. Follow the header comment pattern from `Tier3AuthReactionsTests.swift` with a test inventory comment block.

**Baseline:** At time of writing, the test suite is at approximately 316+ tests (HANDOFF.md Changelog 2026-06-04 line 244: "316 → 331/0" after Tier 3). The engineer should confirm the current count before starting and update the header comment to reflect `baseline + 8` (or fewer if tests 3 and 6 are folded).

---

## 8. Acceptance Criteria

**AC-FT2.1 — Backend RLS verify (Kevin's manual step).**
Kevin runs the verification queries in §3.1. The `pins_delete_own` policy exists with `cmd = 'DELETE'` and `qual` containing `auth.uid() = author_id`. The `votes` FK shows `delete_rule = 'CASCADE'`. If either is missing, Kevin applies §3.2 SQL. This AC is Kevin's gate; `@qa-verifier` confirms Kevin checked it (no programmatic verification available without prod access).

**AC-FT2.2 — Delete button visible only on own pins.**
Tapping any community pin that belongs to the current user shows the delete button in `PinDetailSheet`. The "Still there?" / "Gone" vote buttons are not shown when `isOwnPin == true`.

**AC-FT2.3 — Delete button not visible on others' pins.**
Tapping any community pin where `pin.authorId != authService.currentUserId` (including pins with `author_id = null`) shows the standard vote buttons and no delete button.

**AC-FT2.4 — Confirmation dialog fires on tap.**
Tapping the delete button presents the confirmation dialog with the exact title "Delete this report?" and a destructive "Delete" action and a cancel action.

**AC-FT2.5 — Cancel does nothing.**
Tapping Cancel on the confirmation dialog dismisses the dialog. The pin remains in `visiblePins`. The sheet remains open.

**AC-FT2.6 — Confirm triggers optimistic removal.**
Tapping "Delete" in the confirmation dialog immediately removes the pin from `visiblePins` (map marker disappears) without waiting for the network response.

**AC-FT2.7 — Sheet dismisses on success.**
After a successful server delete (HTTP 2xx), `onDismiss()` is called and the sheet closes.

**AC-FT2.8 — Toast fires after dismiss.**
After the sheet closes, a toast with message "Report deleted." (or Kevin-approved copy per OQ-3) is visible on the map view.

**AC-FT2.9 — Network failure shows error, keeps sheet open.**
If `deleteCrowdPin` throws (network error or non-2xx non-404 response), the sheet stays open and an inline error message appears: "Couldn't delete — please try again." The pin has already been optimistically removed from the map; it will reappear on the next periodic refresh (within 8 seconds) if the delete did not succeed server-side.

**AC-FT2.10 — Double-tap protection.**
While a delete is in-flight (`isLoading == true`), the delete button is disabled. A second tap before the first resolves is a no-op.

**AC-FT2.11 — RLS server-side enforcement.**
A direct `curl` DELETE against `rest/v1/pins?id=eq.<pinId>` with a JWT that does not match `author_id` returns HTTP 403. (Kevin or QA can verify with a test pin in prod; the iOS path never reaches this because the UI guard prevents it.)

**AC-FT2.12 — No vote buttons shown on own pin.**
After FT-2 ships, tapping an own pin never shows the disabled "Still there?" and "Gone" buttons. The own-pin state is unambiguously "delete or close."

**AC-FT2.13 — Live smoke gate (Kevin's manual step).**
Drop an `enforcement_active` or `sweeper_passed` pin using the patrol report sheet. Immediately tap the pin on the map. Confirm:
  (a) The delete button appears.
  (b) Tap Delete → confirmation dialog appears.
  (c) Tap Delete in the dialog → pin disappears from the map immediately.
  (d) "Report deleted." toast appears.
  (e) Tap someone else's pin → no delete button visible, vote buttons present.

**AC-FT2.14 — Votes cascade on server.**
After deleting a pin that has received at least one vote, verify in the Supabase SQL Editor: `select count(*) from public.votes where pin_id = '<deleted-uuid>';` returns 0. (QA or Kevin can verify with a test pin before it expires.)

**AC-FT2.15 — Existing tests still pass.**
All tests that existed before FT-2 still pass. The `isOwnPin` guard tests in `Tier3AuthReactionsTests.swift` pass without modification.

---

## 9. Out of Scope Follow-ups

- **Undo.** A 5-second undo toast ("Report deleted. Undo?") is a common iOS pattern and would be the right UX if hard delete were reconsidered. Kevin locked hard delete; capturing this for a future reconsideration if user feedback surfaces accidental-delete complaints.
- **Admin delete.** A moderator path (delete any pin, not just own) needs a separate role/function, different RLS policy, and UI entry point. Deferred.
- **Durable pin deletion.** The `sign_correction` and `block_note` pin types (`lifespan = 'durable'`) are not yet shipped. When they are, deletion semantics may differ (e.g., audit trail, soft delete). This spec covers ephemeral crowd pins only.
- **Realtime DELETE event handling.** When the supabase-swift SDK is adopted (TF3+ path), Realtime will emit DELETE record events. `CommunityPinService` will need a `mergeRealtimeDeletion(pinId:)` path. The optimistic removal in `deleteCrowdPin` already covers the local case; the missing piece is inbound DELETE events from OTHER users' actions (which don't apply to this feature — you can't delete someone else's pin — but would apply to admin deletes).
