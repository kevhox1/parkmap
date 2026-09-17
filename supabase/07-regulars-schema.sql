-- DRAFT — DO NOT APPLY (Kevin applies at the S-gate per the spec's ceremony plan)
--
-- WePark Regulars network — S1 schema, RLS, RPCs
-- Spec: docs/regulars-network-spec.md §2 (§2.1-§2.7, AS FORMALLY AMENDED at commit `cb464c65` —
-- §0 decisions 6-8, §2.1, §2.6, §2.10. See the MID-FLIGHT RULING ADDENDUM and the QA FIX ROUND
-- ADDENDUM immediately below). Sequencing: docs/regulars-roadmap.md, session S1.
-- Proposed by @backend-data 2026-09-15. QA fix round 2026-09-16 (docs/qa/pr111-regulars-s1-schema.md,
-- FIX-THEN-MERGE). NOT yet applied to production.
-- Kevin applies this via the Supabase SQL Editor — same two-step-if-needed posture as every prior
-- migration, though nothing in this file adds a new enum value, so a single paste is expected to be
-- safe (no STEP 1/STEP 2 split required, matching 04/05's single-paste shape rather than 03's).
-- Run the companion supabase/07-regulars-schema-test.sh after applying.
-- Idempotent: safe to re-run on a clean or partially-applied project (create table/function/view if
-- not exists or create-or-replace, drop-then-create policy/trigger — same convention as every prior
-- migration in this repo).
-- Depends on: 01-mvp-schema.sql (auth.users is Supabase-managed; profiles unaffected here),
-- 02f-block-scoped-restrictions.sql / 03-community-2.0-schema.sql (rate_limit_config table + its
-- "retune by row update, not migration" pattern, reused verbatim in §S1-7 below), 02-pins-schema.sql /
-- 03-community-2.0-schema.sql / 04-community-push-trigger.sql (public.pins + pin_type enum incl.
-- 'leaving_soon', and the current pins_with_author view definition, both extended in §S1-1 below).
--
-- ============================================================================================
-- MID-FLIGHT RULING ADDENDUM (Kevin, 2026-09-15, arrived while this session was already in flight —
-- a formal amendment to docs/regulars-network-spec.md is being written separately; this file does not
-- wait for it, per the coordinator's explicit instruction)
-- ============================================================================================
-- Three items, each addressed below with a pointer to exactly where:
--   1. "2 minutes is nothing... I was thinking 15 minutes" — the spec's original §2.1 recommended a
--      2-minute default inside a [15, 300]-second (15s-5min) CHECK range. Kevin wants the range to
--      "comfortably support minutes-to-tens-of-minutes values." Addressed in §S1-1: the CHECK
--      constraint on pins.regulars_head_start_seconds was widened at the time this ruling landed —
--      ***see the QA FIX ROUND ADDENDUM immediately below: the formal amendment that followed this
--      ruling locked a DIFFERENT, tighter final number than this file first shipped with.*** The
--      client-side default/preset choice (2min vs 15min) is a UX decision for a later iOS session, not
--      a schema concern — this file only sets the server-side range such a default must fit inside; it
--      does not hardcode 15 minutes as the default anywhere.
--   2. NEW capability — scheduled/future departure announcements ("I'm out at 2pm today"). Addressed
--      in §S1-6: regular_notices gains a nullable `scheduled_for timestamptz` column and a
--      derive-expiry trigger so a scheduled notice's expiry is anchored to the announced departure
--      time (plus a grace window), not to the moment it was posted. See §S1-6's PLACEMENT REASONING
--      comment for why this lives on regular_notices rather than on pins or a new table.
--   3. "Head-start can exceed the departure window... the public fallthrough may never fire." Addressed
--      by construction, not by new code: pins.zone_pushed_at (§S1-1) is nullable with no NOT NULL
--      constraint and no trigger anywhere in this file that requires it to ever become non-null — see
--      that column's own comment for the explicit reasoning. This file adds no trigger/RPC that
--      assumes the zone-wide fallthrough phase runs at all for a given leaving_soon pin.
--
-- ============================================================================================
-- QA FIX ROUND ADDENDUM (2026-09-16, docs/qa/pr111-regulars-s1-schema.md, verdict FIX-THEN-MERGE —
-- QA reproduced every item below live against its own scratch Postgres 16 instance)
-- ============================================================================================
-- Six items. The first two are the blocking findings; the rest are amendment-reconciliation drift
-- that accumulated because the formal spec amendment (`cb464c65`) landed on `main` AFTER this branch
-- forked and after the mid-flight ruling above was written, and nobody reconciled the two before this
-- PR's first push.
--   1/2. 🔴 `regular_notices.created_at` and `regular_invites.created_at`/`expires_at` were plain
--      client-writable columns with no privilege lockdown — QA backdated `created_at` in a loop and
--      pushed 16 notices past the 10/hour cap and 26 invites past the 20/day cap (the rate-limit
--      triggers' `count(*) ... where created_at > now() - window` never counts a backdated row), and
--      independently set `regular_invites.expires_at` to +50 years, defeating the 10-minute TTL
--      entirely. This is the *identical* bug class `02f-block-scoped-restrictions.sql`'s own revision
--      history already found and fixed for `pins.created_at`/`source` (three QA rounds deep,
--      `docs/qa/ft15-a-block-scoped-schema-qa-pass3.md` Finding #2) — a column-level `REVOKE` alone is
--      a documented no-op against Supabase's blanket table-level default grant; the fix is table-level
--      `REVOKE` + column-level re-`GRANT`, naming only the columns a client legitimately needs to set.
--      This file already applies that exact pattern correctly to `pins.zone_pushed_at` and to
--      `regular_invites.revoked_at` — it was simply never extended to the three columns that needed it
--      on these two new tables. Fixed in §S1-4 (`regular_invites`) and §S1-6 (`regular_notices`) below,
--      each right after its `CREATE TABLE`, matching this file's own established placement convention.
--   3. 🟡 `regular_notices.scheduled_for` was missing the amended spec's future-only CHECK
--      (`scheduled_for > created_at`) — only the 24h-horizon CHECK existed. QA inserted a past
--      `scheduled_for` and produced a row whose derived `expires_at` landed BEFORE its own `created_at`
--      (already-expired the instant it's created). Fixed in §S1-6: both CHECKs now present, matching
--      the amended spec's §2.6 literally.
--   4. 🟡 `pins.regulars_head_start_seconds`'s CHECK was `[15, 3600]` (this file's own mid-flight-ruling
--      number, item 1 above) but the formal amendment that followed it (§0 decision 6, §2.1) locked a
--      tighter floor: `[60, 3600]`. Fixed in §S1-1: CHECK now reads `between 60 and 3600`, matching
--      `cb464c65` literally. The mid-flight ruling's INTENT (comfortably reach tens of minutes) is
--      preserved; only the exact floor number changes.
--   5. 🟡 `07-regulars-schema-test.sh` had zero coverage for the amended spec's §2.10 items (head-start
--      boundary values, `zone_pushed_at` staying null, `scheduled_for` expiry-derivation correctness)
--      and no dedicated `regular_invite` rate-limit test. Fixed — see the test script's own changelog
--      comment for the added sections, including two permanent regression sections that assert QA's
--      exact two exploit loops now fail.
--   6. 🟡 `docs/regulars-roadmap.md` still stated the pre-amendment "14 sessions + 2 buffer = 16"
--      total with no S10b/S12b rows. Fixed — regenerated against the amended 18-session plan
--      (`docs/regulars-network-spec.md` §5/§8).
--
-- ============================================================================================
-- SCOPE NOTE — what S1 is and is not, and why (read before reviewing the diff)
-- ============================================================================================
-- The spec's own session table (docs/regulars-network-spec.md §5) splits the schema work into S1a
-- ("Core schema: regular_edges, regular_invites, regular_blocks, redeem_regular_invite RPC,
-- block-to-edge-delete trigger") and S1b ("pin_notes, regular_notices, pins columns (§2.1), rate-limit
-- rows (§2.7), the leaving_soon push-timing change + sweep function/cron job (§2.8)"), while also
-- noting "both are one migration file in practice, split here only for review size." This PR's own
-- title ("S1 — schema, RLS, RPCs") and the coordinator's original deliverable list named the
-- trust-graph tables, the Regulars-visible content tables, RLS, the invite RPC, and rate limiting —
-- and, at the time this file was first drafted, deliberately deferred §2.1's `pins` columns alongside
-- §2.8. The mid-flight ruling above pulled §2.1 back INTO this session's scope (the head-start range
-- widening has to land on the same column the ruling is amending). §2.8 remains OUT of scope:
--
-- Still deferred to a follow-up session: §2.8's rewrite of 04-community-push-trigger.sql's live
-- `pins_invoke_send_community_push` WHEN clause, plus the new `sweep_leaving_soon_zone_push()`
-- function and its 30-second pg_cron job. Reasoning, unchanged by the mid-flight ruling:
--   1. §2.8 rewrites the WHEN clause of a trigger that is LIVE IN PRODUCTION TODAY and adds this
--      repo's first-ever sub-minute pg_cron job — the spec's own §8 names the 30-second cadence as its
--      single biggest unproven technical risk. Bundling a live-trigger rewrite into a "DO NOT APPLY,
--      review the trust graph" PR raises this PR's blast radius for no S1 benefit.
--   2. Nothing added in this file depends on that sweep existing: pins.regulars_head_start_seconds and
--      pins.zone_pushed_at are both fully defined, clamped, and commented now, ready for that
--      follow-up to consume — they are inert (never read, never required to be set) until it lands.
--   3. The deferred sweep function's own body calls the ALREADY-DEPLOYED send-community-push Edge
--      Function (unmodified) — it has no dependency on S3's new send-regular-push function — so
--      deferring it costs nothing sequencing-wise.
-- Net effect: zero regression risk to the live push pipeline from this PR. Follow-up TODO logged in
-- docs/regulars-roadmap.md's S1-follow-up row and docs/open-items.md.
--
-- ============================================================================================
-- §S1-1 `pins` — Tiered Handoff head-start marker (spec §2.1, AMENDED per the ruling above)
-- ============================================================================================
alter table public.pins
  add column if not exists regulars_head_start_seconds integer
    check (regulars_head_start_seconds is null
           or regulars_head_start_seconds between 60 and 3600),
  add column if not exists zone_pushed_at timestamptz;

comment on column public.pins.regulars_head_start_seconds is
  'Only meaningful for leaving_soon. How long Regulars get an exclusive, content-bearing push before '
  'the existing zone-wide relevance-gated silent push fires for this pin. Null = no Regulars head '
  'start (poster has zero Regulars, or Regulars are disabled) — falls through to TODAY''S behavior '
  '(the zone push still fires immediately at insert, completely unchanged by this migration: the '
  'trigger rewrite that would actually MAKE this column change push timing is deferred to a follow-up '
  'session — see the SCOPE NOTE above — so this column is fully-defined, clamped schema today with no '
  'live behavioral effect yet). Clamped server-side to [60, 3600] seconds (1 to 60 minutes) — never '
  'trust a client-supplied value outright, same posture as leaving_minutes '
  '(community-2.0-reconciliation-spec.md §2.2). RANGE LOCKED at [60, 3600] per the formal spec '
  'amendment (docs/regulars-network-spec.md §0 decision 6, §2.1, commit cb464c65, 2026-09-15) — '
  'reconciled from this file''s own earlier mid-flight-ruling draft, which had (correctly, in intent, '
  'but not in the final number) widened the original [15, 300] range to [15, 3600] before the amendment '
  'landed with the tighter 60-second floor. Kevin: "2 minutes is nothing... I was thinking 15 minutes." '
  'This column does not hardcode a 15-minute default anywhere — the default/preset ladder (5/10/15/30 '
  'min + Custom) is a client-side UX decision for a later iOS session; this CHECK only sets the '
  'server-side floor/ceiling such a default must fit inside. A value at or past this pin''s own '
  'leaving_minutes countdown is valid and expected, not an error (spec §1.2a''s honest-exclusivity '
  'ruling — the client warns before submit, the server does not reject it). The eventual client-side '
  'stepper''s bounds MUST match [60, 3600] verbatim — the spec''s own '
  'testAppConstants_regularsHeadStartRange_matchesServerClamp guard test (docs/regulars-roadmap.md) '
  'exists specifically so the two can never silently drift.';
comment on column public.pins.zone_pushed_at is
  'Stamped the moment the DELAYED zone-wide push fires for a leaving_soon pin with a head start — a '
  'future sweep function''s job (deferred, see the SCOPE NOTE above; no such sweep exists in this '
  'migration). Null for every other pin type/path, and, as of this migration, null for EVERY '
  'leaving_soon pin too, since nothing here ever sets it. DELIBERATELY nullable with no NOT NULL '
  'constraint and no trigger anywhere in this file that requires it to eventually become non-null: '
  'Kevin''s mid-flight ruling explicitly notes that a head start CAN exceed a pin''s own departure/'
  'expiry window (e.g. a 15-minute head start on a pin whose own expires_at is only ~13 minutes out, '
  'per derive_pin_expiry()''s leaving_minutes+3 formula) — in that case the pin may expire and be swept '
  'by the existing hygiene job (03-community-2.0-schema.sql §2.12) before the zone-wide fallthrough '
  'phase ever runs. That is a valid, expected outcome, not a bug — no part of this schema, RLS policy, '
  'or RPC in this file assumes zone_pushed_at is ever guaranteed to become non-null for a given row.';

grant insert (regulars_head_start_seconds) on public.pins to anon, authenticated;
-- Column-level grant required per 02f-block-scoped-restrictions.sql's fail-closed model: that file
-- REVOKEd blanket table-level INSERT/UPDATE on public.pins from anon/authenticated and re-GRANTed it
-- back column-by-column — by that file's own stated design, a new pins column is NOT client-writable
-- until explicitly added to a GRANT list here. zone_pushed_at is deliberately EXCLUDED from this
-- grant, same reasoning 03-community-2.0-schema.sql already documents for excluding claimed_by from
-- its own grant lists: only a server-side SECURITY DEFINER writer (a future sweep function, not built
-- in this session) should ever be able to set it.

-- pins_with_author — append the two new columns. Same "p.* is frozen at CREATE VIEW time" bug class
-- 02f section 5 and 03/04's own view recreations already fixed for this exact view — required again
-- here or these two columns would never reach any client (iOS/PWA both read pins exclusively via this
-- view). Full explicit column list below is 04-community-push-trigger.sql's exact list (the most
-- recent prior recreation, which already includes author_avatar), with the two new columns appended
-- at the end — appending to an explicit SELECT list is always a safe CREATE OR REPLACE.
create or replace view public.pins_with_author as
  select
    p.id,
    p.pin_type,
    p.source,
    p.lifespan,
    p.lat,
    p.lng,
    p.segment_id,
    p.zone_id,
    p.author_id,
    p.created_at,
    p.updated_at,
    p.expires_at,
    p.resolved_at,
    p.confirm_count,
    p.dispute_count,
    p.meta,
    p.notes,
    pr.username    as author_username,
    pr.reputation  as author_reputation,
    p.starts_at,
    p.report_group_id,
    p.position_fraction,
    p.leaving_minutes,
    p.claimed_by,
    pr.avatar      as author_avatar,
    p.regulars_head_start_seconds,
    p.zone_pushed_at
  from public.pins p
  left join public.profiles pr on pr.id = p.author_id;

grant select on public.pins_with_author to anon, authenticated;

-- ============================================================================================
-- §S1-2 `regular_edges` — the trust graph itself (spec §2.2)
-- ============================================================================================
create table if not exists public.regular_edges (
  low_user_id  uuid not null references auth.users(id) on delete cascade,
  high_user_id uuid not null references auth.users(id) on delete cascade,
  created_at   timestamptz not null default now(),
  check (low_user_id < high_user_id),
  primary key (low_user_id, high_user_id)
);

comment on table public.regular_edges is
  'The Regulars trust graph — one row per mutually-consented relationship, canonically ordered '
  '(low_user_id < high_user_id) so an undirected edge never needs a symmetric pair of rows. The ONLY '
  'writer is redeem_regular_invite() (§S1-4 below), a SECURITY DEFINER function that proves both sides '
  'consented (one created the invite, the other redeemed it) before it ever inserts a row — no client '
  'role has an INSERT policy on this table at all. This is the single most sensitive table this feature '
  'adds; deny-by-default is the whole point.';

alter table public.regular_edges enable row level security;

drop policy if exists regular_edges_select_own on public.regular_edges;
create policy regular_edges_select_own on public.regular_edges
  for select using (auth.uid() in (low_user_id, high_user_id));
-- Reasoning: either party to the relationship may see it (needed for the Regulars settings list on
-- both sides, and for pin_notes/regular_notices' own policies below, which join through this table).
-- No third party — not even another one of either user's own Regulars — can see this row; a Regulars
-- list is not transitively visible.

-- Deliberately NO insert policy for anon or authenticated. An edge is a trust claim about ANOTHER
-- account — a client must never be able to POST one directly, since that would let any authenticated
-- session assert a friendship with an arbitrary uid with zero consent from the other side. The only
-- path to a row existing is redeem_regular_invite() (§S1-4), which runs as SECURITY DEFINER and
-- therefore bypasses RLS entirely for its own write — this table needing no INSERT policy is a feature
-- of that design, not a gap.

drop policy if exists regular_edges_delete_own on public.regular_edges;
create policy regular_edges_delete_own on public.regular_edges
  for delete using (auth.uid() in (low_user_id, high_user_id));
-- Reasoning: either party can end the relationship unilaterally — the same "delete your own thing"
-- ethos as FT-2's own-pin delete (docs/ft2-delete-own-pin-spec.md), extended here to "delete your own
-- relationship." No update policy: edges are immutable facts once created — "unfriend" is a delete, not
-- an edit. The DELETE...RETURNING PostgREST default is satisfied by regular_edges_select_own above
-- (the row being deleted always has auth.uid() as one of its two participants, which is exactly what
-- that SELECT policy requires) — the S11/PR#100 RETURNING lesson applies to DELETE exactly as it does
-- to INSERT/UPDATE, and is closed here by the SELECT policy already existing before this one is added.

-- ============================================================================================
-- §S1-3 `regular_blocks` — directed, owner-only-visible (spec §2.3)
-- ============================================================================================
create table if not exists public.regular_blocks (
  user_id         uuid not null references auth.users(id) on delete cascade,
  blocked_user_id uuid not null references auth.users(id) on delete cascade,
  created_at      timestamptz not null default now(),
  check (user_id <> blocked_user_id),
  primary key (user_id, blocked_user_id)
);

comment on table public.regular_blocks is
  'Directed, owner-only-visible block list. Blocking a user severs any live regular_edges row between '
  'the two accounts in the same transaction (see the trigger below) and is checked on every future '
  'redeem_regular_invite() call, not just at invite-creation time, so a blocked party cannot re-add via '
  'an invite link they already hold.';

alter table public.regular_blocks enable row level security;

drop policy if exists regular_blocks_select_own on public.regular_blocks;
create policy regular_blocks_select_own on public.regular_blocks
  for select using (user_id = auth.uid());
drop policy if exists regular_blocks_insert_own on public.regular_blocks;
create policy regular_blocks_insert_own on public.regular_blocks
  for insert with check (user_id = auth.uid());
drop policy if exists regular_blocks_delete_own on public.regular_blocks;
create policy regular_blocks_delete_own on public.regular_blocks
  for delete using (user_id = auth.uid());
-- Reasoning: deliberately NO policy of any kind lets the blocked party discover they were blocked —
-- the same convention most consumer apps follow, and it closes off a path to retaliation against the
-- blocker. Only the blocker's own session can ever read/write their own block list — a blocked_user_id
-- appearing as the SECOND column of someone else's row is never visible to that second party, only to
-- the row's own user_id. INSERT/DELETE RETURNING is satisfied by regular_blocks_select_own above
-- (user_id = auth.uid() is true for every row this role can insert or delete) — same S11 RETURNING
-- pattern as regular_edges, closed the same way.

create or replace function public.delete_regular_edge_on_block()
returns trigger language plpgsql security definer as $$
begin
  delete from public.regular_edges
  where low_user_id = least(new.user_id, new.blocked_user_id)
    and high_user_id = greatest(new.user_id, new.blocked_user_id);
  return new;
end; $$;

comment on function public.delete_regular_edge_on_block() is
  'Fires after every regular_blocks insert. SECURITY DEFINER because the row it deletes belongs to '
  'regular_edges, a table the calling client role has no delete policy path to reach for the OTHER '
  'party''s benefit here — the trigger runs as the function owner, bypassing RLS, same posture as every '
  'other SECURITY DEFINER trigger in this repo (award_confirm_reputation, auto_resolve_on_dispute, '
  'etc.). Blocking always severs an existing edge in the same transaction as the block insert — a '
  'blocked party never has a live relationship left over to exploit.';

drop trigger if exists regular_blocks_delete_edge on public.regular_blocks;
create trigger regular_blocks_delete_edge
  after insert on public.regular_blocks
  for each row execute function public.delete_regular_edge_on_block();

-- ============================================================================================
-- §S1-4 `regular_invites` — short-lived, single-use tokens; QR and link are the SAME token
-- (spec §2.4, decision 5: "both QR and share link, same underlying token")
-- ============================================================================================
create table if not exists public.regular_invites (
  id           uuid primary key default gen_random_uuid(),
  created_by   uuid not null references auth.users(id) on delete cascade,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default (now() + interval '10 minutes'),
  redeemed_by  uuid references auth.users(id) on delete set null,
  redeemed_at  timestamptz,
  revoked_at   timestamptz
);

comment on table public.regular_invites is
  'A single-use, 10-minute invite token. The row''s own id (a uuid) IS the token embedded in both the '
  'QR code and the share link (wepark://invite/<id>) rendered client-side — one code path renders two '
  'presentations, per the spec''s "both QR and link, same token" ruling, not two independent '
  'mechanisms. Rows are kept forever, redeemed/revoked/expired alike, purely so '
  'enforce_regular_invite_rate_limit() (§S1-7) has a durable, delete-proof count to work from — the '
  'same "count a durable log, not a live/deletable set" reasoning this repo already applies to '
  'block_scoped_report_log and reputation_award_log.';

alter table public.regular_invites enable row level security;

drop policy if exists regular_invites_select_own on public.regular_invites;
create policy regular_invites_select_own on public.regular_invites
  for select using (created_by = auth.uid());
-- Reasoning: deliberately NOT selectable by token for an anonymous or arbitrary authenticated reader —
-- closes an enumeration path where scanning/guessing token ids could leak an inviter's identity before
-- redemption even happens. The redeeming side never reads this table directly at all; it only ever
-- calls redeem_regular_invite() (below), which looks the row up as the SECURITY DEFINER function
-- owner, bypassing this policy entirely by design.

drop policy if exists regular_invites_insert_own on public.regular_invites;
create policy regular_invites_insert_own on public.regular_invites
  for insert with check (created_by = auth.uid());
-- RETURNING on this insert is satisfied by regular_invites_select_own above (created_by = auth.uid()
-- is exactly this policy's own WITH CHECK, so the newly-inserted row always passes the SELECT check
-- too) — the S11/PR#100 RETURNING lesson, closed by construction here rather than discovered live.

revoke insert on public.regular_invites from anon, authenticated;
grant insert (created_by) on public.regular_invites to anon, authenticated;
-- QA FIX ROUND, Finding #2 (docs/qa/pr111-regulars-s1-schema.md — live-reproduced, FIX-THEN-MERGE):
-- table-level REVOKE + column-level re-GRANT, the exact `02f-block-scoped-restrictions.sql` pattern
-- already proven for `pins.created_at`/`source` (docs/qa/ft15-a-block-scoped-schema-qa-pass3.md
-- Finding #2) and already applied elsewhere in THIS file (pins.zone_pushed_at above,
-- regular_invites.revoked_at below) — it was simply never extended to this table's INSERT path.
-- Without this, RLS alone does NOT stop a client from setting created_at/expires_at explicitly on
-- INSERT: regular_invites_insert_own's WITH CHECK only constrains created_by, so a plain
-- `POST /regular_invites {created_by: me, created_at: <50 years ago>}` was RLS-permitted and QA
-- reproduced it live — 25 backdated inserts, zero rejections, 26 rows for one creator against a
-- 20/24h cap (enforce_regular_invite_rate_limit()'s `count(*) ... where created_at > now() - window`
-- never counts a row backdated past the window), and independently, `expires_at = now() + 50 years`
-- succeeded outright, defeating the spec's stated 10-minute invite TTL entirely (no trigger on this
-- table overwrites expires_at the way regular_notices_derive_expiry does for regular_notices — the
-- column-privilege lockdown is the ONLY defense here, not a belt-and-suspenders addition). A plain
-- column-level REVOKE on top of Supabase's untouched table-level default grant would be a silent
-- no-op (02f's own documented ACL-merge behavior — table- and column-level grants for the same
-- privilege are OR'd, not narrowed by each other); REVOKE must happen at the table level first. Only
-- `created_by` is re-GRANTed: id/created_at/expires_at all keep their column DEFAULTs (every
-- legitimate insert path omits them), and redeemed_by/redeemed_at/revoked_at stay null at insert time
-- exactly as before — no legitimate write path is narrowed by this fix, only the exploit is closed.

revoke update on public.regular_invites from anon, authenticated;
grant update (revoked_at) on public.regular_invites to authenticated;
-- Column-level lockdown, one step further than the spec's literal text, mirroring 02f's fail-closed
-- column-privilege model (02f-block-scoped-restrictions.sql "grant insert (...)"/"grant update (...)")
-- rather than leaving every column open to a same-row PATCH. Without this, regular_invites_update_own
-- below would let a creator directly PATCH redeemed_by/redeemed_at/expires_at on their own row via a
-- plain REST call — none of that creates a real trust edge (only redeem_regular_invite() ever writes
-- to regular_edges), but it would let a creator misrepresent their own invite's redemption state in a
-- way their own client trusts (the invite sheet's "redeemed" success state, spec §3.2), and it
-- needlessly widens the surface a compromised client could use to interfere with this table's own
-- rate-limit accounting log. Restricting the client-writable column set to exactly revoked_at (the
-- only field the spec's own "Cancel" flow needs to set) closes that off while leaving "cancel" fully
-- functional.
drop policy if exists regular_invites_update_own on public.regular_invites;
create policy regular_invites_update_own on public.regular_invites
  for update using (created_by = auth.uid()) with check (created_by = auth.uid());
-- Lets the creator set revoked_at on their own still-open invite ("Cancel" in the invite sheet, spec
-- §3.2) — and, per the column grant immediately above, ONLY revoked_at; redeemed_by/redeemed_at/
-- expires_at/created_by remain unreachable by any client-side UPDATE regardless of this USING/WITH
-- CHECK clause, because Postgres checks column-level privileges before RLS ever evaluates. No delete
-- policy — invites are kept, revoked or expired, for the rate-limit accounting described above.
-- RETURNING is satisfied by regular_invites_select_own (created_by = auth.uid() is this policy's own
-- USING clause).

create or replace function public.redeem_regular_invite(p_token uuid)
returns jsonb language plpgsql security definer as $$
declare
  v_invite public.regular_invites%rowtype;
  v_low uuid;
  v_high uuid;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;

  select * into v_invite from public.regular_invites
  where id = p_token
    and revoked_at is null
    and redeemed_at is null
    and expires_at > now()
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'reason', 'expired_or_used');
  end if;

  if v_invite.created_by = auth.uid() then
    return jsonb_build_object('ok', false, 'reason', 'cannot_add_self');
  end if;

  if exists (
    select 1 from public.regular_blocks
    where (user_id = v_invite.created_by and blocked_user_id = auth.uid())
       or (user_id = auth.uid() and blocked_user_id = v_invite.created_by)
  ) then
    return jsonb_build_object('ok', false, 'reason', 'blocked');
  end if;

  v_low := least(v_invite.created_by, auth.uid());
  v_high := greatest(v_invite.created_by, auth.uid());

  insert into public.regular_edges (low_user_id, high_user_id)
  values (v_low, v_high)
  on conflict (low_user_id, high_user_id) do nothing;

  update public.regular_invites
  set redeemed_by = auth.uid(), redeemed_at = now()
  where id = p_token;

  return jsonb_build_object('ok', true, 'regular_id', v_invite.created_by);
end; $$;

comment on function public.redeem_regular_invite(uuid) is
  'Race-safe invite redemption. RACE-SAFETY APPROACH: `SELECT ... FOR UPDATE` takes a row lock on the '
  'invite the instant it is read, combined with the `redeemed_at is null` predicate in that same '
  'SELECT — two devices calling this function with the same token concurrently serialize on the row '
  'lock; whichever transaction commits first sees `redeemed_at is null` and proceeds, the second '
  'transaction''s `SELECT ... FOR UPDATE` blocks until the first commits, then re-evaluates the WHERE '
  'clause against the now-committed row and finds `redeemed_at` no longer null, so it falls through to '
  '`if not found` and returns `expired_or_used` — never a double edge, never a double-counted '
  'redemption. Same single-writer-wins SHAPE as claim_pin() '
  '(03-community-2.0-schema.sql, community-2.0-reconciliation-spec.md §2.10), expressed as an explicit '
  'row lock rather than a bare `UPDATE ... WHERE ... IS NULL` because this function has to branch '
  '(self-add, blocked) before it can decide whether to write at all, and `UPDATE` alone cannot express '
  'the read of an invite it intends to leave unmodified. The `on conflict (low_user_id, high_user_id) '
  'do nothing` on the regular_edges insert is a second, independent safety net for the case where an '
  'edge already exists from an earlier invite between the same two accounts — the invite still gets '
  'marked redeemed, and the RPC still reports ok:true, but no duplicate/conflicting row is ever '
  'attempted.';

grant execute on function public.redeem_regular_invite(uuid) to authenticated;
-- Not granted to anon: auth.uid() is null for anon regardless, so the function would only ever raise
-- for that role — but an explicit EXECUTE grant limited to authenticated matches the "authenticated
-- sessions only" intent stated in the function body rather than relying solely on the runtime check,
-- same convention as claim_pin(uuid)'s own grant in 03-community-2.0-schema.sql.

-- ============================================================================================
-- §S1-5 `pin_notes` — the ONLY free text attached to a public pin, and it is NOT public (spec §2.5)
-- ============================================================================================
create table if not exists public.pin_notes (
  pin_id     uuid primary key references public.pins(id) on delete cascade,
  author_id  uuid not null references auth.users(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 80),
  created_at timestamptz not null default now()
);

comment on table public.pin_notes is
  'The optional short note on a leaving_soon Tiered Handoff post ("front spot, plug''s a little '
  'loose"). Deliberately NOT a column on pins itself: pins_select_public already grants broad public '
  'read of every non-parked_car row (the standing pin-visibility rule, HANDOFF.md 2026-08-24), so a '
  'note column added directly to pins would inherit that public-by-default visibility and defeat the '
  'entire point of a Regulars-only note. This side table gets its own, narrower SELECT policy instead. '
  'This is a third visibility posture alongside the standing rule''s PERSONAL-LOCATION (private, '
  'author-only) and COMMUNITY REPORTS (public): REGULARS-VISIBLE — content attached to an otherwise-'
  'public pin, visible only to the author and their Regulars, never to a stranger browsing the same '
  'public pin. A deliberate, documented evolution of the standing rule, not a violation of it.';

alter table public.pin_notes enable row level security;

drop policy if exists pin_notes_select_own_or_regular on public.pin_notes;
create policy pin_notes_select_own_or_regular on public.pin_notes
  for select using (
    author_id = auth.uid()
    or exists (
      select 1 from public.regular_edges re
      where (re.low_user_id = pin_notes.author_id or re.high_user_id = pin_notes.author_id)
        and auth.uid() in (re.low_user_id, re.high_user_id)
    )
  );
-- Reasoning: the author always sees their own note (needed for their own posted-pin card); any current
-- Regular of the author sees it too (the entire point of the table); everyone else — including a
-- stranger who can already see the PUBLIC pin itself via pins_select_public — gets zero rows for this
-- table, filtered silently by RLS, not an error. A block (regular_blocks) already deletes the
-- underlying regular_edges row in the same transaction (§S1-3's trigger), so a blocked former Regular
-- loses this SELECT path the instant they are blocked, with no separate check needed here.

drop policy if exists pin_notes_insert_own on public.pin_notes;
create policy pin_notes_insert_own on public.pin_notes
  for insert with check (author_id = auth.uid());
-- RETURNING satisfied by pin_notes_select_own_or_regular's first branch (author_id = auth.uid()) —
-- closed by construction, same pattern as every other table in this file.

drop policy if exists pin_notes_delete_own on public.pin_notes;
create policy pin_notes_delete_own on public.pin_notes
  for delete using (author_id = auth.uid());
-- No update policy — a note is immutable once posted, matching "not a chat app" (no editing a message
-- after the fact either, spec decision 2).

create or replace function public.enforce_pin_note_ownership()
returns trigger language plpgsql security definer as $$
begin
  if not exists (
    select 1 from public.pins
    where id = new.pin_id and author_id = new.author_id and pin_type = 'leaving_soon'
  ) then
    raise exception 'pin_notes.author_id must match the leaving_soon pin''s own author'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end; $$;

comment on function public.enforce_pin_note_ownership() is
  'Closes a gap the RLS policies above cannot close on their own: pin_notes_insert_own only proves the '
  'CALLER is author_id, it says nothing about whether pin_id actually belongs to that same caller, or '
  'whether pin_id is even a leaving_soon pin. Without this trigger, an authenticated session could '
  'attach a note to ANY pin (including one they do not own, or a non-leaving_soon type this feature '
  'was never meant to touch) as long as they set author_id = their own uid — the FK to pins alone does '
  'not enforce ownership or pin_type, only existence.';

drop trigger if exists pin_notes_enforce_ownership on public.pin_notes;
create trigger pin_notes_enforce_ownership
  before insert on public.pin_notes
  for each row execute function public.enforce_pin_note_ownership();

-- ============================================================================================
-- §S1-6 `regular_notices` — the Quick Regulars Notice ("moving my car") AND the scheduled/future
-- departure announcement ("I'm out at 2pm today") (spec §2.6, extended per the mid-flight ruling)
-- ============================================================================================
create table if not exists public.regular_notices (
  id            uuid primary key default gen_random_uuid(),
  sender_id     uuid not null references auth.users(id) on delete cascade,
  body          text not null check (char_length(body) between 1 and 140),
  scheduled_for timestamptz,
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null default (now() + interval '60 minutes'),
  check (scheduled_for is null or scheduled_for > created_at),
  check (scheduled_for is null or scheduled_for <= created_at + interval '24 hours')
);

-- QA FIX ROUND, Finding #3 (docs/qa/pr111-regulars-s1-schema.md): the future-only CHECK
-- (`scheduled_for > created_at`) was missing entirely — only the 24h-horizon CHECK existed. QA
-- inserted `scheduled_for = now() - interval '1 day'` and it was accepted, producing a row whose
-- derived `expires_at` (`scheduled_for + 60min`, see the trigger below) landed BEFORE its own
-- `created_at` — a notice already expired the instant it is created. Both CHECKs now match the
-- amended spec (docs/regulars-network-spec.md §2.6, commit `cb464c65`) literally. The
-- derive-expiry trigger's formula itself was already correct (QA confirmed by trace) — the bug was
-- the missing input-validation guard around it, not the anchoring math.

comment on table public.regular_notices is
  'One-way, ephemeral broadcast to a sender''s whole Regulars list. NOT a message thread — no '
  'recipient-scoped read state, no reply, no per-recipient targeting, and structurally no place a '
  'conversation could live (single sender_id + single body per row, no parent/thread/recipient '
  'column of any kind) — this table cannot become a chat feature by accretion. Visible to the sender '
  'and to every current Regular of the sender until expires_at. The client composes body client-side '
  'from a canned-phrase prefix plus optional free text before insert; the server stores and RLS-gates '
  'the final string only, it does not parse its internal structure. '
  'EXTENDED per Kevin''s mid-flight ruling, 2026-09-15 ("People also usually plan they''re leaving... '
  'they could tell their Regulars, I''m out at 2pm today"): scheduled_for (nullable — null = the '
  'original immediate-notice shape, byte-identical to every pre-ruling row) lets a sender announce a '
  'FUTURE departure instead of only an immediate one. PLACEMENT REASONING (this capability could have '
  'gone on pins or a new table instead — recorded here for the spec amendment to reconcile against): '
  'this lives on regular_notices, not pins, because (a) it is semantically a Regulars-only heads-up — '
  'exactly this table''s existing purpose and RLS shape — not a map pin; a scheduled departure has no '
  'location to disclose and creating one speculatively would be a genuinely NEW disclosure the spec''s '
  'decision 3 (no standing/passive visibility) does not currently cover; (b) pins.leaving_minutes is a '
  'small fixed countdown set {5,10,15,20} representing "leaving imminently now," structurally the wrong '
  'shape for an announcement that can be hours out; conflating the two would force derive_pin_expiry() '
  'and the "pin is public the instant it posts" rule (spec decision 3) to handle a pin that describes a '
  'future event before that event exists, which is a materially different, unscoped feature; (c) no new '
  'table is needed — regular_notices already IS the one-way, Regulars-only, ephemeral broadcast '
  'primitive Kevin''s literal example describes ("tell their Regulars"). Not a new table, not a step '
  'toward a thread/inbox model — still no reply, no read receipts, no per-recipient targeting; a '
  'scheduled notice is a temporal attribute of the SAME notice concept, nothing more.';

alter table public.regular_notices enable row level security;

drop policy if exists regular_notices_select_own_or_regular on public.regular_notices;
create policy regular_notices_select_own_or_regular on public.regular_notices
  for select using (
    sender_id = auth.uid()
    or exists (
      select 1 from public.regular_edges re
      where (re.low_user_id = regular_notices.sender_id or re.high_user_id = regular_notices.sender_id)
        and auth.uid() in (re.low_user_id, re.high_user_id)
    )
  );
-- Same shape and reasoning as pin_notes_select_own_or_regular above: sender sees their own sent
-- notices, any current Regular sees them too, everyone else gets zero rows, RLS-filtered not errored.
-- Unaffected by scheduled_for — visibility is about WHO, not WHEN; a scheduled notice is exactly as
-- visible to Regulars, before or after the announced time, as an immediate one. expires_at bounds how
-- long a notice is fetchable at all (§S1-8's hygiene note covers cleanup); it is not itself an RLS
-- predicate — an expired-but-not-yet-swept row is already useless product-wise (the client filters by
-- expires_at client-side, same "TTL-hides-before-hygiene-sweeps" precedent as pins), so no extra "and
-- expires_at > now()" clause is added here to keep this policy's shape identical to pin_notes' proven
-- one.

drop policy if exists regular_notices_insert_own on public.regular_notices;
create policy regular_notices_insert_own on public.regular_notices
  for insert with check (sender_id = auth.uid());
-- RETURNING satisfied by regular_notices_select_own_or_regular's first branch (sender_id = auth.uid()).

revoke insert on public.regular_notices from anon, authenticated;
grant insert (sender_id, body, scheduled_for) on public.regular_notices to anon, authenticated;
-- QA FIX ROUND, Finding #1 (docs/qa/pr111-regulars-s1-schema.md — live-reproduced, FIX-THEN-MERGE):
-- same table-level REVOKE + column-level re-GRANT pattern as regular_invites above (and as
-- `pins.created_at`/`source` in `02f-block-scoped-restrictions.sql`). Without this,
-- regular_notices_insert_own's WITH CHECK only constrains sender_id — a client could set an explicit
-- past `created_at` on INSERT, and enforce_regular_notice_rate_limit()'s `count(*) ... where
-- created_at > now() - window` would never count that row. QA reproduced this live: 15 sequential
-- backdated inserts, zero rejections, 16 total rows for one sender against a 10/hour cap. Only
-- sender_id/body/scheduled_for are re-GRANTed: id/created_at keep their column DEFAULTs (every
-- legitimate insert omits them), and expires_at needs NO lockdown of its own — its own BEFORE INSERT
-- trigger (regular_notices_derive_expiry, below) unconditionally overwrites whatever the client sends
-- for it, verified live, so excluding it from this GRANT is belt-and-suspenders, not load-bearing.

drop policy if exists regular_notices_delete_own on public.regular_notices;
create policy regular_notices_delete_own on public.regular_notices
  for delete using (sender_id = auth.uid());
-- Lets a sender retract an accidental notice early — same "delete your own thing" ethos as
-- regular_edges/FT-2 above. No update policy — a notice is immutable once sent, matching "not a chat
-- app" (spec decision 2) exactly as pin_notes does. This also means a scheduled notice cannot be
-- RESCHEDULED after posting, only cancelled outright (delete) and re-posted — a deliberate consequence
-- of keeping "immutable once sent" universal rather than carving out an exception for the new
-- scheduled_for column.

create or replace function public.derive_regular_notice_expiry()
returns trigger language plpgsql security definer as $$
begin
  if new.scheduled_for is not null then
    new.expires_at := new.scheduled_for + interval '60 minutes';
  else
    new.expires_at := now() + interval '60 minutes';
  end if;
  return new;
end; $$;

comment on function public.derive_regular_notice_expiry() is
  'Never trusts a client-supplied expires_at (same posture as derive_pin_expiry(),'
  ' 03-community-2.0-schema.sql §2.11) — always overwrites it server-side. EXPIRY RULE (the mid-flight'
  ' ruling''s structural answer to "the spec''s flat 60-minute-from-post expiry only fits immediate'
  ' notices"): an immediate notice (scheduled_for null) expires 60 minutes after it is POSTED, exactly'
  ' as before the ruling. A scheduled notice expires 60 minutes after the ANNOUNCED departure time'
  ' instead — so a notice posted at 10am saying "I''m out at 2pm" stays visible/actionable through'
  ' roughly 3pm, not disappearing at 11am (60 minutes after posting, while the departure is still hours'
  ' away and the notice is most useful). The 60-minute grace window is the same constant either way,'
  ' just anchored to a different instant depending on whether scheduled_for is set.';

drop trigger if exists regular_notices_derive_expiry on public.regular_notices;
create trigger regular_notices_derive_expiry
  before insert on public.regular_notices
  for each row execute function public.derive_regular_notice_expiry();

-- ============================================================================================
-- §S1-7 Rate limiting — generalize the existing rate_limit_config pattern, no new shape (spec §2.7)
-- ============================================================================================
-- rate_limit_config already exists (02f-block-scoped-restrictions.sql), already designed to be
-- retuned by row UPDATE rather than by migration, and already carries a max_rows column this feature
-- does not need a second guard for (same "currently unused by design" posture 03-community-2.0-schema
-- already documents for its own two single-guard keys, ephemeral_report/durable_crowd_report — seeded
-- regardless so a future second guard can be wired up without a schema change if ever required).
insert into public.rate_limit_config (key, max_count, window_hours, max_rows)
values
  ('regular_invite', 20, 24, 60),
  ('regular_notice', 10, 1, 30)
on conflict (key) do nothing;

-- `regular_invite` (20/24h): generous enough to add a whole block of Regulars in one sitting, and not
-- a plausible spam vector on its own even at the cap — an unredeemed invite is inert; the only thing an
-- attacker gains from generating tokens nobody scans is 20 harmless rows.
-- `regular_notice` (10/1h): bounds the one genuinely repeatable, other-facing action in this spec — a
-- compromised or bored account pushing its own Regulars list over and over. Kevin's mid-flight ruling
-- adds scheduled/future notices (§S1-6) but does not change this cap's shape: a scheduled notice is
-- still exactly one row, counted exactly like an immediate one.

create or replace function public.enforce_regular_invite_rate_limit()
returns trigger language plpgsql security definer as $$
declare
  v_max_count    integer;
  v_window_hours integer;
  v_recent_rows  integer;
begin
  select max_count, window_hours
    into v_max_count, v_window_hours
    from public.rate_limit_config
   where key = 'regular_invite';

  if v_max_count is null then
    v_max_count := 20; v_window_hours := 24; -- belt-and-suspenders fallback, matches the seeded row
  end if;

  select count(*)
    into v_recent_rows
    from public.regular_invites
   where created_by = new.created_by
     and created_at > now() - (v_window_hours || ' hours')::interval;

  if v_recent_rows >= v_max_count then
    raise exception 'rate limit exceeded: max % regular_invite row(s) per % hour(s)', v_max_count, v_window_hours
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end; $$;

comment on function public.enforce_regular_invite_rate_limit() is
  'Single-guard count against public.regular_invites itself, not a separate log table — safe here '
  'because, unlike block_scoped_report_log''s history, regular_invites rows are never deleted by any '
  'client-facing policy (no DELETE policy exists on this table, §S1-4), so a delete-then-reinsert '
  'bypass of this count is not reachable. Mirrors enforce_crowd_report_rate_limit() '
  '(03-community-2.0-schema.sql) in shape: config-driven thresholds, SECURITY DEFINER, raises 42501 '
  'over the cap.';

drop trigger if exists regular_invites_enforce_rate_limit on public.regular_invites;
create trigger regular_invites_enforce_rate_limit
  before insert on public.regular_invites
  for each row execute function public.enforce_regular_invite_rate_limit();

create or replace function public.enforce_regular_notice_rate_limit()
returns trigger language plpgsql security definer as $$
declare
  v_max_count    integer;
  v_window_hours integer;
  v_recent_rows  integer;
begin
  select max_count, window_hours
    into v_max_count, v_window_hours
    from public.rate_limit_config
   where key = 'regular_notice';

  if v_max_count is null then
    v_max_count := 10; v_window_hours := 1; -- belt-and-suspenders fallback, matches the seeded row
  end if;

  select count(*)
    into v_recent_rows
    from public.regular_notices
   where sender_id = new.sender_id
     and created_at > now() - (v_window_hours || ' hours')::interval;

  if v_recent_rows >= v_max_count then
    raise exception 'rate limit exceeded: max % regular_notice row(s) per % hour(s)', v_max_count, v_window_hours
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end; $$;

comment on function public.enforce_regular_notice_rate_limit() is
  'Single-guard count against public.regular_notices itself, keyed on created_at (post time), NOT '
  'scheduled_for (announced departure time) — a burst of 11 scheduled-for-later notices posted within '
  'one hour still trips this guard exactly like 11 immediate ones would, which is the correct target: '
  'the cap bounds posting VOLUME, not how far in the future those posts point. '
  'regular_notices_delete_own (§S1-6) DOES let a sender retract their own notice early, which is a '
  'theoretical delete-then-reinsert count bypass this guard does not close — accepted, documented gap, '
  'same "known limitation, not closed here" style 02f already uses for its own BEFORE-INSERT-only gap. '
  'If this is exploited in practice, port block_scoped_report_log''s append-only-ledger pattern rather '
  'than adding a second live-count guard.';

drop trigger if exists regular_notices_enforce_rate_limit on public.regular_notices;
create trigger regular_notices_enforce_rate_limit
  before insert on public.regular_notices
  for each row execute function public.enforce_regular_notice_rate_limit();

-- ============================================================================================
-- §S1-8 Hygiene note (documentation only — no new pg_cron job in this file)
-- ============================================================================================
-- regular_notices rows become product-invisible the moment expires_at passes (client-side filter,
-- same TTL precedent as public.pins) well before any server-side sweep would run — this holds equally
-- for immediate and scheduled notices, since both now have a correctly server-derived expires_at
-- (§S1-6). This file does not add a dedicated hygiene sweep for regular_notices/regular_invites — the
-- existing community-pin-expiry-hygiene-sweep cron job (03-community-2.0-schema.sql §2.12) only
-- touches public.pins and is left untouched here. Unbounded row growth on regular_notices/
-- regular_invites is a pure storage-hygiene concern, not a correctness or privacy one (both tables are
-- already fully RLS-gated regardless of age), and is deferred to whichever follow-up session lands
-- §2.8's sweep infrastructure (see the SCOPE NOTE above) rather than inventing a second one-off cron
-- job here.
