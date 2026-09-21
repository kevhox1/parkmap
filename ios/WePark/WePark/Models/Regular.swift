//
//  Regular.swift
//  WePark
//
//  Regulars network — S5 (iOS model layer). Spec: docs/regulars-network-spec.md §2 (wire shapes
//  taken verbatim from the MERGED schema, `supabase/07-regulars-schema.sql` — that file, not the
//  spec's own SQL sketch, is the wire-truth for every CodingKeys mapping below, per S1's QA fix
//  round reconciling a few numbers the spec sketch got superseded on). Sequencing:
//  docs/regulars-roadmap.md, session S5.
//
//  Four plain, synthesized-shape `Codable` structs — one per net-new Regulars table this
//  migration adds. Deliberately NOT a discriminated/associated-value model (unlike
//  `CommunityPin`'s `PinMeta`) — none of these four rows carry a polymorphic payload the way
//  `pins.meta` does.
//
//  Zero UI in this file or this session (S5 scope, docs/regulars-network-spec.md §5 row S5).
//  `AppConstants.regularsEnabled` (Services/Constants.swift) stays `false` — nothing here is
//  reachable from a live view yet.
//
//  Date decoding: every `timestamptz` column below is decoded as `Date` using the SAME custom
//  ISO8601 strategy (with-fractional-seconds, falling back to without) already established by
//  `ZoneMessageService.decodeResponse`/`CommunityPinService.makeDateDecodingJSONDecoder()` — the
//  decoder itself lives on `RegularsService` (`Services/RegularsService.swift`), not duplicated
//  here, mirroring `ZoneMessage`'s own "plain Codable struct, decoder lives in the owning
//  service" split.
//
//  No Calendar.current. No hardcoded Supabase secrets.
//

import Foundation

// MARK: - RegularEdge

/// One row of `public.regular_edges` — the Regulars trust graph itself (spec §2.2,
/// `07-regulars-schema.sql` §S1-2). Canonically ordered (`low_user_id < high_user_id` is a DB
/// CHECK) so an undirected "we are Regulars" relationship never needs a symmetric pair of rows.
///
/// No client `INSERT` path exists for this table at all — the ONLY writer is the
/// `redeem_regular_invite` RPC (§S1-4), a `SECURITY DEFINER` function that proves both sides
/// consented before it ever writes a row. This type is therefore read/delete-only from the
/// client's perspective: `RegularsService.fetchEdges()` reads it, `regular_edges_delete_own`
/// (either party may unfriend unilaterally) is the only client-reachable mutation, and this
/// session (S5) does not wire that delete path — see `RegularsService`'s own header for the
/// exact S5 method inventory.
///
/// Composite primary key `(low_user_id, high_user_id)` — no synthetic `id` column exists on this
/// table, so `Identifiable.id` below is a computed, non-decoded property, not a wire field.
struct RegularEdge: Identifiable, Codable, Equatable {
    let lowUserId: UUID
    let highUserId: UUID
    let createdAt: Date

    /// Computed, not decoded — this table's real primary key is the composite
    /// `(lowUserId, highUserId)`. Stable and unique per row without needing a server-side `id`.
    var id: String { "\(lowUserId.uuidString)_\(highUserId.uuidString)" }

    enum CodingKeys: String, CodingKey {
        case lowUserId  = "low_user_id"
        case highUserId = "high_user_id"
        case createdAt  = "created_at"
    }

    /// Returns the OTHER participant's id given the caller's own id — the id that actually
    /// matters to a Regulars-list UI ("who is this a Regulars edge WITH"), since a fetch of
    /// "my edges" always returns rows where the caller is one of the two participants but the
    /// low/high ordering doesn't reveal which one to the current user by itself.
    ///
    /// Returns `nil` if `ownUserId` matches neither side — defensive only; every row a
    /// `regular_edges_select_own`-gated fetch can return always has the caller on one side by
    /// construction, so this should never actually happen for `RegularsService`'s own fetch
    /// results.
    func otherUserId(ownUserId: UUID) -> UUID? {
        if lowUserId == ownUserId { return highUserId }
        if highUserId == ownUserId { return lowUserId }
        return nil
    }
}

// MARK: - RegularInvite

/// One row of `public.regular_invites` — a single-use, 10-minute invite token (spec §2.4,
/// `07-regulars-schema.sql` §S1-4). The row's own `id` IS the token rendered as both the QR code
/// and the share link (`wepark://invite/<id>`, spec decision 5) — one code path, two
/// presentations, not two independent mechanisms. Building that QR/link presentation is S7 UI
/// scope, out of this session.
///
/// Client-writable columns on `INSERT` are `created_by` ONLY (`grant insert (created_by) on
/// public.regular_invites to anon, authenticated` — §S1-4's QA-fixed column-level lockdown).
/// `id`/`created_at`/`expires_at` all carry server-side `DEFAULT`s; sending any of them
/// explicitly is rejected by the table-level `REVOKE` that lockdown put in place — S1's QA pass
/// live-reproduced exactly that exploit (backdating `created_at`/inflating `expires_at`) before
/// the fix landed, so `RegularsService.createInvite()` must never attempt to set them.
/// `redeemed_by`/`redeemed_at` are exclusively `SECURITY DEFINER`-written by
/// `redeem_regular_invite()`. `revoked_at` is the ONE column a client may `UPDATE` on their own
/// still-open invite (`grant update (revoked_at) ...` — the "Cancel" affordance, spec §3.2) —
/// this session does not wire that update path either; see `RegularsService`'s header.
struct RegularInvite: Identifiable, Codable, Equatable {
    let id: UUID
    let createdBy: UUID
    let createdAt: Date
    let expiresAt: Date
    /// `nil` until redeemed. Set server-side by `redeem_regular_invite()` — never client-written.
    let redeemedBy: UUID?
    /// `nil` until redeemed. Same server-only-write posture as `redeemedBy`.
    let redeemedAt: Date?
    /// `nil` unless the creator cancelled this invite via the (S5-unwired) `revoked_at` update
    /// path.
    let revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case createdBy  = "created_by"
        case createdAt  = "created_at"
        case expiresAt  = "expires_at"
        case redeemedBy = "redeemed_by"
        case redeemedAt = "redeemed_at"
        case revokedAt  = "revoked_at"
    }
}

// MARK: - RegularInviteRedeemResult

/// The four terminal states `redeem_regular_invite(uuid)` (`07-regulars-schema.sql` §S1-4) can
/// return, decoded from that RPC's `jsonb` response body — see `RegularsService.redeemInvite`'s
/// decode logic for the `{"ok": ..., "reason": ..., "regular_id": ...}` wire shape this maps
/// from. Deliberately NOT a `throw`-per-failure-case design: per the RPC's own SQL, every one of
/// these (including the three failure reasons) is a normal `2xx` HTTP response with a
/// `ok: false` payload, not an error status — a client mapping any of them to a thrown Swift
/// error would have to reconstruct the distinction this enum already carries losslessly.
enum RegularInviteRedeemResult: Equatable {
    /// The invite was valid and unredeemed; a `regular_edges` row now exists (or already did,
    /// per the RPC's own `on conflict ... do nothing` — either way `ok: true`).
    /// `regularId` is the invite's own `created_by` — the person who is now a Regular.
    case success(regularId: UUID)
    /// The token was already redeemed, revoked, or past its 10-minute `expires_at` — the RPC's
    /// `SELECT ... FOR UPDATE ... IF NOT FOUND` branch.
    case expiredOrUsed
    /// The redeeming session IS this invite's own `created_by` — a self-add attempt.
    case cannotAddSelf
    /// A `regular_blocks` row exists between the two accounts, in either direction.
    case blocked
}

// MARK: - PinNote

/// One row of `public.pin_notes` — the optional, short, Regulars-only note attached to a
/// `leaving_soon` Tiered Handoff post (spec §2.5, `07-regulars-schema.sql` §S1-5). Deliberately
/// NOT a column on `pins`/`CommunityPin` itself — see that table's own comment for why a
/// Regulars-scoped note needs a side table with its OWN, narrower `SELECT` policy rather than
/// inheriting `pins`' standing public-read posture. This is the third pin-visibility posture this
/// app has (alongside PERSONAL-LOCATION and COMMUNITY REPORTS, `HANDOFF.md` 2026-08-24):
/// REGULARS-VISIBLE.
///
/// `pinId` is this table's own primary key (one note per pin, enforced by the schema's
/// `pin_id uuid primary key`) — `Identifiable.id` below is that same column, not a synthetic
/// value, matching `ZoneMessage`'s convention of using whatever the server's real primary key is
/// rather than inventing a wrapper id.
///
/// Unlike `regular_invites`/`regular_notices`, this table's `INSERT` grant was NOT
/// column-locked down by S1's QA fix round (only `author_id`'s ownership is enforced, via the
/// `enforce_pin_note_ownership` `BEFORE INSERT` trigger — see that trigger's own comment in
/// `07-regulars-schema.sql`) — `RegularsService`'s write path still only ever sends
/// `pin_id`/`author_id`/`body` (never an explicit `created_at`), matching this codebase's
/// standing "let server defaults apply, don't send a column just because nothing stops you"
/// discipline even where the schema doesn't force it.
struct PinNote: Identifiable, Codable, Equatable {
    let pinId: UUID
    let authorId: UUID
    let body: String
    let createdAt: Date

    var id: UUID { pinId }

    enum CodingKeys: String, CodingKey {
        case pinId     = "pin_id"
        case authorId  = "author_id"
        case body
        case createdAt = "created_at"
    }
}

// MARK: - RegularNotice

/// One row of `public.regular_notices` — the one-way, ephemeral "moving my car" broadcast to a
/// sender's whole Regulars list (spec §2.6, `07-regulars-schema.sql` §S1-6), extended by the
/// 2026-09-15 mid-flight ruling to also carry a Scheduled Departure ("I'm out at 2pm today").
///
/// `scheduledFor` (nullable) is the ENTIRE Scheduled Departure wire surface on this type:
/// `nil` = an ordinary, send-now notice, byte-identical to the pre-ruling shape; non-`nil` = a
/// declared future departure time. `expiresAt` is ALWAYS server-derived
/// (`derive_regular_notice_expiry`, a `BEFORE INSERT` trigger that unconditionally overwrites
/// whatever `expires_at` the client sent) — anchored to `scheduledFor + 60 minutes` when set, or
/// `createdAt + 60 minutes` otherwise. Never trust a client-computed `expiresAt` for anything;
/// always decode the server's own value.
///
/// Client-writable columns on `INSERT` are `sender_id`, `body`, `scheduled_for` ONLY (`grant
/// insert (sender_id, body, scheduled_for) on public.regular_notices to anon, authenticated` —
/// §S1-6's QA-fixed column-level lockdown, the same bug class/fix as `regular_invites` above).
/// `id`/`created_at` carry server defaults; `expires_at` is unconditionally trigger-derived
/// regardless of what's sent. `RegularsService.sendNotice(...)` must never attempt to set
/// `created_at`/`expires_at` explicitly.
struct RegularNotice: Identifiable, Codable, Equatable {
    let id: UUID
    let senderId: UUID
    let body: String
    /// Non-`nil` only for a Scheduled Departure notice (the "I'm out at ___" canned phrase,
    /// spec §3.5). `nil` for every other canned phrase / ordinary send-now notice.
    let scheduledFor: Date?
    let createdAt: Date
    /// Always server-derived — see this type's own doc comment. Anchored past `scheduledFor`
    /// when present, past `createdAt` otherwise; both cases include the same 60-minute grace
    /// window.
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case senderId     = "sender_id"
        case body
        case scheduledFor = "scheduled_for"
        case createdAt    = "created_at"
        case expiresAt    = "expires_at"
    }
}
