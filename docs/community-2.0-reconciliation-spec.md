# Community 2.0 — Reconciliation Spec (Build 20)

**Status:** SPEC — Phase 0 (backend-data) can start now, in parallel with PR #91. iOS phases (1–4)
wait for #91 to merge, per Kevin's instruction.
**Owner:** Tech Lead (this spec) → `@backend-data` (Phase 0) → `@ios-engineer` (Phases 1–4, in order)
→ `@designer` (Phase 1 sheet-detent review, Phase 2 report-flow review) → `@qa-verifier` per PR.
**Trigger:** Kevin's Claude-design session — `design/claude-code-prompt.md` (the build brief) +
`design/prototype.html` (the working prototype, values lifted verbatim below) — plus Kevin's four
2026-08-26 decisions on leaving-soon, timing, push, and zones (encoded throughout, not reopened).
**Supersedes / reframes:** `docs/community-1.0-direction.md` and `docs/community-1.0-buildplan.md`
where they conflict (the June Tier 1/2/3 taxonomy is **already shipped as `pin_type`, `source`,
`lifespan`** — see §1). Does **not** touch the 2026-06-01 enforcement-framing decision (direction
§6) or the anonymous-auth/no-signup-wall decision (§6.3) — both already hold and the new design is
consistent with them. Does **not** touch `docs/patrol-mode-feasibility-spec.md`'s subject (the
coverage-sweep smart parking route) — see §4's numbering note, that doc is a different feature that
also currently claims "build 20."
**Explicitly not this spec's subject:** the smart-parking-route / "patrol mode" feature. Two
unrelated docs have now claimed build 20; §4 flags this for Kevin to resolve.
**Extends / touches:** `supabase/01-mvp-schema.sql`, `supabase/02-pins-schema.sql` (+02e/02f),
`ios/WePark/WePark/Models/CommunityPin.swift`, `Services/CommunityPinService.swift`,
`Views/BrowseNavigationSheet.swift` (FT-20 sheet), `Views/ReportSheet.swift`,
`Views/BlockRestrictionReportSheet.swift` (reused, not rebuilt — see §1), `Views/ParkedCarDetailView.swift`,
`Services/NotificationScheduler.swift`, `ContentView.swift`.

---

## §0 Open Questions for Kevin (read before code starts)

Two. Everything else in the brief was decidable from the docs + code, and the decision is stated
inline with its reasoning rather than punted here.

**OQ-1 — Zone shape: bounding box (matches today's schema) or true polygon?**
Kevin's brief says "seed Nolita, SoHo, LES as three NTA-derived polygons." `public.zones`
(`supabase/01-mvp-schema.sql:35-44`) only stores an axis-aligned box (`lat_min/lat_max/lng_min/lng_max`) —
there is no PostGIS geometry column, and it's unknown whether the PostGIS extension is even enabled
on this project. A real polygon needs a schema addition (`geography(Polygon)` column + a
point-in-polygon zone lookup) — a bigger, riskier Phase 0 lift than three rectangles.
**Recommendation: ship three bounding boxes for v1** (Nolita/SoHo/LES rectangles carved out of the
existing `soho-les` box — they're adjacent, not far-flung, so rectangles are a reasonable NTA
approximation) and treat true polygon geometry as a follow-up if the boxes visibly misclassify
blocks in practice. **Needs Kevin's go to downgrade "polygon" to "box" rather than silently
substituting.**

**OQ-2 — Which TTLs govern: the new design's or FT-1's already-shipped ones?**
**✅ RESOLVED by Kevin 2026-08-26: the prototype's numbers govern — enforcement 45m, sweeper 120m.**
His reasoning reframes the pin's semantics: it is not only "agent is here NOW" but "agent already
came through — unlikely to swing back soon," so an aged pin is *useful history*, not stale noise.
The staleness is the signal. Two implementation consequences: (1) §2.6's TTL-derivation trigger uses
45m/120m; FT-1's 5-minute values in `CommunityPinService.ephemeralTTLSeconds(for:)` are updated in
Phase 1 (with a code comment pointing here — FT-1's "they moved on" observation is answered by
always showing age, not by expiring fast); (2) every surface that renders these pins MUST show
relative age ("reported X min ago"), which the design already does on all of them — that display
rule is what makes the long TTL honest. The confirm-to-extend (+15m, 2h cap) mechanic is unchanged.
`open_spot` 3m and `leaving_soon` stated+3m are unaffected.
*(Original question preserved below for the record.)*
The design prototype (`design/prototype.html:1003`) specifies `enforcement: 45m, sweeper: 120m`.
But `CommunityPinService.ephemeralTTLSeconds(for:)` (`Services/CommunityPinService.swift:1197-1206`)
**already ships** `enforcement_active` / `sweeper_passed` at **5 minutes**, a deliberate FT-1 change
("mobile, very fresh... a 30-min lifetime kept them on the map long after they'd moved on") extendable
+15 min per confirm up to a 2h cap via the existing `extend_pin_expiry` RPC. This is a real,
verified-in-code conflict between the new design and a shipped, reasoned product decision — not
something inferable from the docs. **Recommendation: keep FT-1's 5-minute baseline** (it's live,
already reasoned, and the confirm-to-extend mechanic already delivers the same "stays visible while
still true" outcome the design's longer numbers were going for) and treat the design's 45m/120m as
stale mockup values from before FT-1 shipped. `open_spot` (3m) and `leaving_soon` (stated + 3m) are
net-new types with no shipped conflict — those numbers carry over as specified. **Needs Kevin's
confirmation either way before Phase 0's TTL-derivation trigger (§2.6) is written.**

---

## §1 Delta table — every design surface/primitive vs. today's codebase

Verified against the files/lines cited; "extend" means the primitive exists and needs a bounded
change, "net-new" means nothing today does this.

| Design surface/primitive | Status | Evidence |
|---|---|---|
| Typed pin table, two-axis `source`/`lifespan` | **Exists, unmodified** | `supabase/02-pins-schema.sql:39-75`. This IS the June Tier 1/2/3 taxonomy — direction doc §4/§5 is already schema. |
| `enforcement_active`, `sweeper_passed`, `filming`, `construction`, `sign_correction`, `block_note`, `broken_meter` pin types | **Exists, unmodified** | `pin_type` enum, `02-pins-schema.sql:17-34`; iOS mirror `Models/CommunityPin.swift:48-63`. |
| `open_spot`, `leaving_soon` pin types | **Net-new** | Absent from the enum (verified: `docs/patrol-mode-feasibility-spec.md` §0 independently confirmed `open_spot` absent 2026-08-24). §2.1. |
| `position_fraction` (where along the curb) | **Net-new** | No such column or meta key anywhere in `pins` or `CommunityPin.swift`. §2.2. |
| `heading_toward` (direction picker) | **Exists (FT-11), reuse as-is** | `meta.heading_toward`, `EnforcementActiveMeta`/`SweeperPassedMeta` (`CommunityPin.swift:506-570`), already drives a compass-bearing chevron on the map marker (`MapViewRepresentable.swift:1491-1554`). Two-value `from`/`to` (segment endpoints), not three named cross-streets — semantically the same choice, cosmetically different labels. No schema change; `ReportSheet.swift` already has a working `HeadingTowardPicker`. |
| Confirm ("Still there?") extends TTL, capped | **Exists (Tier 3 sub-PR #1), unmodified** | `extend_pin_expiry` RPC, `02-pins-schema.sql:247-266` (+15 min, capped at now+2h); `CommunityPinService.callExtendPinExpiry` (`CommunityPinService.swift:1361-1389`). |
| Dispute/"Gone" shortens/hides | **Exists, different mechanism than the prototype's** | Shipped: 3-dispute threshold auto-hides (`supabase/02e-auto-resolve-trigger.sql`). Prototype: single "Gone" tap immediately shrinks TTL to now+2min (`prototype.html:1068-1071`). §2.7 recommends keeping the shipped 3-vote threshold rather than parallel-building single-tap decay. |
| Rep math (+5 report / +2 confirm / +1 chat) | **Net-new — a dormant TODO exists with different math** | `02e-auto-resolve-trigger.sql:75-77` TODO sketches "+2 to *author* on 3rd confirm" — never built, and a different model (threshold-based, author-only) than the design's (immediate, per-action, confirmer gets the +2). §2.6 supersedes the TODO explicitly. |
| Rate-limiting, server-side | **Exists for one report type, generalize** | `rate_limit_config` table + `enforce_block_scoped_rate_limit()` (`supabase/02f-block-scoped-restrictions.sql:704-840`) — currently scoped to block-scoped filming/construction only. §2.8 generalizes the pattern to ephemeral crowd reports. |
| Anonymous auth, no signup wall | **Exists, unmodified** | `SupabaseAuthService.signInAnonymously()`, silent on launch. Direction §6.3 stands. |
| Handle + avatar identity sheet | **Net-new** | No `profiles` row is ever created from iOS today — `SupabaseAuthService.swift` never calls a profiles insert (grep-confirmed). `profiles.avatar` column doesn't exist. §2.5, §3.2. |
| "Street closure" report (filming/construction, photo, durable) | **Already fully built (FT-15/TF2-15) — reuse, don't rebuild** | `Views/BlockRestrictionReportSheet.swift` — multi-block map-tap select, required photo evidence, date-window picker, rate-limited insert via `insertBlockScopedReport`. This is a *superset* of the design's "closure" tile (which just says "photo helps" — same idea). §3.3 wires the new Report grid's 4th tile straight to this existing sheet. |
| "Confirm the street" step (guessed block + up to 3 alternatives) | **Precedent exists, not reused yet for reports** | `ParkConfirmView`'s "Wrong street?" up-to-3-alternatives-within-35m pattern (W5, `docs/w5-pin-drop-spec.md`) is structurally the same UX. `ReportSheet.swift` today skips this step entirely (takes the injected coordinate/segment as-is). §3.3 extracts and reuses the W5 pattern rather than inventing a new one. |
| Crew feed (zone chat + report cards, one list, newest-first) | **Net-new UI; underlying data is two different tables today** | `zone_messages` (chat, zone-anchored) + `pins` (reports) are fetched by two different, currently-unconnected code paths. No unified feed view exists. §3.1. |
| Blockface-anchored chat | **Extend `zone_messages`, don't parallel it** | `zone_messages` has `zone_id` only, no per-block anchor (`01-mvp-schema.sql:72-80`). §2.4 adds a nullable `segment_id`. |
| Zone chips (Nolita / SoHo / LES) | **Data operation on existing `zones` table** | One row (`soho-les`) exists today (`01-mvp-schema.sql:52-67`). §2.3. |
| One Realtime channel per zone | **Delta from the brief — current architecture is different and should stay that way** | `CommunityPinService.startRealtime()` (`CommunityPinService.swift:578-618`) is **one table-wide** `public.pins` WebSocket subscription, filtered client-side by `RealtimeMergeGate` (viewport + pin-type eligibility) — explicitly NOT split by any server-side predicate, because `postgres_changes` filters can't express compound predicates (documented in-line, `CommunityPinService.swift:560-577`). Opening N zone-scoped channels would multiply socket count for no benefit the client-side gate doesn't already provide. **Recommendation: keep one channel, add `zone_id` as one more `RealtimeMergeGate` dimension** (alongside pin-type + viewport) rather than building per-zone channels. |
| Rep/tenure/accuracy/helped-count profile row | **Net-new columns** | `profiles` only has `reputation` today. §2.5. |
| Leaving-soon spot handoff | **Net-new — Kevin's reversal of direction §4's deferral, encoded here** | See callout below. |
| Device push token + APNs sender | **Net-new, schema-only in Phase 0** | No `device_push_tokens`-shaped table exists. `NotificationScheduler.swift` is 100% local (`UNCalendarNotificationTrigger`) — confirmed no APNs/remote registration anywhere in `ios/WePark`. §2.9, §3.4. |
| Curb-color legality palette (red/amber/green/orange/gray) | **Sacred, untouched** | `Services/ParkingColors.swift`. No community surface introduces a new color in this family — see §3 per-phase notes. |
| FT-20 bottom sheet (2 custom detents: peek + medium, minimal content) | **Extend — needs a 3rd detent** | `Views/BrowseNavigationSheet.swift` — Kevin explicitly rejected extra chrome at REST (3-icon row → 1 button + 1 link, `§0f`). The crew feed is not extra chrome at rest — it's new content at a taller, opt-in pulled-up state, matching the design's own collapsed/half/full model. Flagged as the highest-regression-risk touch point in this spec (§4). |

**Leaving-soon callout (Kevin's decision, 2026-08-26 — reverses `community-1.0-direction.md` §4):**
Spot handoff **is in v1** (Phase 4), informational and free, with "spots can't be held — first come,
first served" copy (`prototype.html:325`) and a claim that only dims the pin
(`prototype.html:203-208`, `1072-1075`). **§5 requires the same commit that lands Phase 4 to add a
superseded-marker to `community-1.0-direction.md` §4** pointing here — don't let two docs disagree
silently.

---

## §2 Phase 0 — Schema Extension Spec (backend-data, no UI, starts now)

Everything below is **one migration file**, `supabase/03-community-2-schema.sql`, following the
existing numbering convention (01 = MVP chat, 02(+letters) = pins/community delta). **Kevin applies
it to production by hand, as with every prior migration — this spec produces the file and a test
script, never an applied schema.**

### §2.1 `pin_type` enum additions

```sql
-- Must run as its own statement, committed, before anything in this same script
-- references the new values (Postgres restriction on ALTER TYPE ... ADD VALUE).
alter type public.pin_type add value if not exists 'open_spot';
alter type public.pin_type add value if not exists 'leaving_soon';
```

Both fall through the **existing** `pins_insert_crowd` and `pins_select_public` RLS policies
unchanged — neither policy restricts by `pin_type`, so **no RLS delta is needed for these two
types.** Both are public-by-default, consistent with the standing privacy rule: `leaving_soon` posts
at the car's exact position, but only via an explicit, user-initiated "Hand your spot to the crew"
tap — a deliberate disclosure, not an ambient leak, so it does not need the `parked_car` precedent's
lockdown. Any *future* personal-location type must still follow that precedent.

### §2.2 `pins` table — two new columns

```sql
alter table public.pins
  add column if not exists position_fraction double precision
    check (position_fraction is null or (position_fraction between 0 and 1)),
  add column if not exists leaving_minutes integer
    check (leaving_minutes is null or leaving_minutes in (5, 10, 15, 20)),
  add column if not exists claimed_by uuid references auth.users(id);

comment on column public.pins.position_fraction is
  'Position along the blockface, [0,1] from the segment''s "from" endpoint to its "to" endpoint '
  '(same directional convention as meta.heading_toward). Null = render at segment midpoint '
  '(every existing pin type''s current, unchanged behavior).';
comment on column public.pins.leaving_minutes is
  'User-chosen countdown for a leaving_soon pin (5/10/15/20). Used for display copy and to derive '
  'expires_at server-side (§2.6) — never trust a client-supplied expires_at for this type.';
comment on column public.pins.claimed_by is
  'Single-claimant "I''m heading there" marker for leaving_soon pins. Set exactly once via the '
  'claim_pin RPC (§2.10) — first writer wins, informational only, never a reservation.';
```

Nullable on every existing row and every existing pin type — zero migration risk, matches the
`starts_at`/`report_group_id` precedent from FT-15.

### §2.3 Zones — data operation, not a code path

Insert three new rows; **do not delete or rewrite `soho-les`.** `zone_messages.zone_id` is
`references public.zones(id) on delete cascade` (`01-mvp-schema.sql:74`) — deleting that row would
cascade-delete every historical SoHo/LES chat message. Leave it as an inert archive:

```sql
update public.zones set
  description = 'Legacy — superseded 2026-08-26 by nolita/soho/les. Retained for chat history; no new pins/messages should target this id.'
where id = 'soho-les';

insert into public.zones (id, name, description, lat_min, lat_max, lng_min, lng_max) values
  ('nolita', 'Nolita', 'Nolita, NY', 40.7217, 40.7256, -73.9967, -73.9930),
  ('soho',   'SoHo',   'SoHo, NY',   40.7220, 40.7280, -74.0050, -73.9970),
  ('les',    'LES',    'Lower East Side, NY', 40.7145, 40.7230, -73.9920, -73.9800)
on conflict (id) do update set
  name = excluded.name, description = excluded.description,
  lat_min = excluded.lat_min, lat_max = excluded.lat_max,
  lng_min = excluded.lng_min, lng_max = excluded.lng_max;
```

Boxes are placeholders pending OQ-1 — swap for real NTA-derived coordinates once Kevin rules.

### §2.4 Blockface-anchored messages — extend `zone_messages`

```sql
alter table public.zone_messages
  add column if not exists segment_id text;

create index if not exists zone_messages_segment_created_idx
  on public.zone_messages(segment_id, created_at desc)
  where segment_id is not null;
```

Nullable — every pre-existing PWA zone-chat row (segment-less) keeps working unchanged. No RLS
delta: `zone_messages_insert_user` already lets an authenticated author set any column on their own
insert.

### §2.5 `profiles` — identity + trust-loop columns

```sql
alter table public.profiles
  add column if not exists avatar text,
  add column if not exists helped_count integer not null default 0,
  add column if not exists accurate_report_count integer not null default 0,
  add column if not exists total_report_count integer not null default 0;

-- The handle is decorative, not a login identifier — dedupe collisions client-side-friendly
-- (two neighbors both picking "MottStRegular" is a cosmetic non-issue, not a security one).
alter table public.profiles drop constraint if exists profiles_username_key;
```

`created_at` (already exists) is tenure. `accurate_report_count / total_report_count` back a
client-computed accuracy percentage (`accurate / total`, guard divide-by-zero client-side for a
brand-new poster) rather than a stored percentage that would need its own recompute trigger.

### §2.6 Reputation — server-computed, supersedes the `02e` TODO

Three triggers, mirroring the existing `refresh_pin_vote_counts` / `auto_resolve_on_dispute` style
(`SECURITY DEFINER`, narrow, single-purpose). All three **upsert** the profiles row so reputation
still accrues to a user who has never opened the identity sheet (device has an `auth.uid()` from
anonymous auth the moment it does anything — a display handle is optional, a reputation-bearing row
is not):

```sql
create or replace function public.award_report_reputation()
returns trigger language plpgsql security definer as $$
begin
  if new.source = 'crowd' and new.author_id is not null then
    insert into public.profiles (id, username, reputation, total_report_count)
    values (new.author_id, 'neighbor-' || substr(new.author_id::text, 1, 8), 5, 1)
    on conflict (id) do update set
      reputation = public.profiles.reputation + 5,
      total_report_count = public.profiles.total_report_count + 1,
      updated_at = now();
  end if;
  return null;
end; $$;

drop trigger if exists pins_award_report_reputation on public.pins;
create trigger pins_award_report_reputation
  after insert on public.pins
  for each row execute function public.award_report_reputation();

create or replace function public.award_confirm_reputation()
returns trigger language plpgsql security definer as $$
begin
  if new.vote = 'confirm' then
    insert into public.profiles (id, username, reputation, helped_count)
    values (new.user_id, 'neighbor-' || substr(new.user_id::text, 1, 8), 2, 1)
    on conflict (id) do update set
      reputation = public.profiles.reputation + 2,
      helped_count = public.profiles.helped_count + 1,
      updated_at = now();
  end if;
  return null;
end; $$;

drop trigger if exists votes_award_confirm_reputation on public.votes;
create trigger votes_award_confirm_reputation
  after insert on public.votes
  for each row execute function public.award_confirm_reputation();

create or replace function public.award_chat_reputation()
returns trigger language plpgsql security definer as $$
begin
  if new.message_type = 'user' and new.author_id is not null then
    insert into public.profiles (id, username, reputation)
    values (new.author_id, 'neighbor-' || substr(new.author_id::text, 1, 8), 1)
    on conflict (id) do update set
      reputation = public.profiles.reputation + 1,
      updated_at = now();
  end if;
  return null;
end; $$;

drop trigger if exists messages_award_chat_reputation on public.zone_messages;
create trigger messages_award_chat_reputation
  after insert on public.zone_messages
  for each row execute function public.award_chat_reputation();

-- accurate_report_count: fires once, the first time a pin the caller authored gets its first
-- confirm — same no-double-fire shape as auto_resolve_on_dispute (column-scoped trigger).
create or replace function public.award_accuracy_on_first_confirm()
returns trigger language plpgsql security definer as $$
begin
  if new.confirm_count = 1 and old.confirm_count = 0 and new.author_id is not null then
    update public.profiles set
      accurate_report_count = accurate_report_count + 1,
      updated_at = now()
    where id = new.author_id;
  end if;
  return null;
end; $$;

drop trigger if exists pins_award_accuracy_on_first_confirm on public.pins;
create trigger pins_award_accuracy_on_first_confirm
  after update of confirm_count on public.pins
  for each row execute function public.award_accuracy_on_first_confirm();
```

**Supersedes** `02e-auto-resolve-trigger.sql:75-77`'s TODO (author +2 on 3rd confirm) — leave that
comment in place with a one-line pointer to this file rather than deleting it, per this repo's "link
to superseded work, don't delete" convention. `auto_resolve_on_dispute` itself (the 3-dispute
auto-hide) is unchanged and still fires independently.

### §2.7 "Gone" — reuse the shipped 3-dispute mechanism, don't parallel-build single-tap decay

The prototype's "Gone" button immediately shrinks a pin's TTL to +2 minutes on a single tap
(`prototype.html:1068-1071`). The shipped mechanism is a 3-dispute threshold that hides the pin
outright (`auto_resolve_on_dispute`, already live). **Recommendation: map "Gone" → `upsertVote(pinId, .dispute)`**,
reusing the existing vote path unchanged, rather than adding a second decay mechanism. This is a
deliberate, documented deviation from the prototype's literal behavior, chosen because the shipped
mechanism is already proven, already gamed-resistant (3 votes vs. 1), and needs zero new schema.
Revisit only if live use shows 3 votes is too slow for a 3-minute `open_spot` pin — if so, the fix is
a `rate_limit_config`-style tunable threshold, not a rebuild.

### §2.8 Rate limiting — generalize the existing pattern

`rate_limit_config` (`02f-block-scoped-restrictions.sql:704-721`) is already designed to be
retuned by row update, not migration. Add one more key and a general trigger mirroring
`enforce_block_scoped_rate_limit()`'s shape, scoped to ephemeral crowd reports (enforcement/sweeper/
open_spot — `leaving_soon` is naturally self-limiting, one active pin per parked car):

```sql
insert into public.rate_limit_config (key, max_count, window_hours, max_rows)
values ('ephemeral_report', 20, 1, 60)
on conflict (key) do nothing;

-- enforce_ephemeral_report_rate_limit(): same shape as enforce_block_scoped_rate_limit
-- (count this author's rows in the trailing window, reject with 42501 over the cap).
-- Full body omitted here — @backend-data ports it directly from 02f's existing function,
-- swapping the qualifying-row predicate to (source='crowd' and lifespan='ephemeral').
```

### §2.9 Device push tokens — schema + sender seam only (Phase 4 builds the pipeline)

```sql
create table if not exists public.device_push_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  apns_token   text not null,
  environment  text not null check (environment in ('sandbox', 'production')),
  zone_id      text references public.zones(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (user_id, apns_token)
);

alter table public.device_push_tokens enable row level security;
-- Deliberately NO select policy at all — device tokens are never read by any client role,
-- only by the sender Edge Function via the service-role key (bypasses RLS). Same
-- deny-by-default posture as rate_limit_config.
create policy device_push_tokens_insert_own on public.device_push_tokens
  for insert with check (auth.uid() = user_id);
create policy device_push_tokens_update_own on public.device_push_tokens
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy device_push_tokens_delete_own on public.device_push_tokens
  for delete using (auth.uid() = user_id);
```

**Privacy-preserving design note (important — resolves an otherwise-unstated tension):** rule 5
("push only when a report touches the user's parked car's blockface") needs *some* way to know
relevance, but the standing privacy rule forbids uploading `parked_car` location to the server at
all. **Recommendation: `zone_id` is the only location signal a device ever uploads** (coarse,
already-public, non-personal — it's the same zone concept every user already sees in the UI). The
Phase 4 pipeline (§3.4) sends a **silent** (`content-available`) push to every device subscribed to
a zone when a new ephemeral pin lands there; the *client* — which is the only party that ever knew
its own parked segment — compares the payload's `segment_id` against its own on-device
`ParkedCar.segmentId` and only then surfaces a user-visible local notification via the existing
`UNUserNotificationCenter` path. The server never learns which blockface any device cares about,
only which zone. This is a schema/architecture recommendation, not an open question — flagging it
because it isn't stated anywhere in the brief and materially shapes §3.4.

Sender seam (Phase 4 implements the body): `supabase/functions/send-community-push/index.ts`,
mirroring `ingest-film-permits/index.ts`'s existing shape — Deno Edge Function, service-role secrets
from `Deno.env`, invoked via a `pg_net.http_post` trigger on `pins` INSERT for ephemeral crowd types,
same pattern as `internal.invoke_film_permit_ingest()` (`02d-ingest-cron.sql:81-109`).

### §2.10 `claim_pin` RPC

```sql
create or replace function public.claim_pin(p_pin_id uuid)
returns boolean language plpgsql security definer as $$
declare
  v_updated int;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = 'insufficient_privilege';
  end if;
  update public.pins set claimed_by = auth.uid(), updated_at = now()
  where id = p_pin_id and pin_type = 'leaving_soon' and claimed_by is null;
  get diagnostics v_updated = row_count;
  return v_updated > 0;  -- false = someone already claimed it; client shows "someone beat you to it"
end; $$;
```

Single `UPDATE ... WHERE claimed_by IS NULL` is naturally race-safe — first caller wins, second gets
`false` back, no separate locking needed.

### §2.11 Server-derived `expires_at` — closes a pre-existing gap while touching this code

Today, `expires_at` on every crowd insert is **entirely client-supplied**
(`CommunityPinService.insertCrowdPin`, `CommunityPinService.swift:1251-1263` — the client computes it
and puts it straight in the POST body). Pre-existing, not introduced by this feature — but
`leaving_soon`'s variable, user-chosen TTL (`leaving_minutes` + 3) makes it more attackable (nothing
stops a modified client from sending `leaving_minutes: 9999` today). Since this migration already
touches `pins` INSERT machinery, add a `BEFORE INSERT` trigger that derives/clamps `expires_at`
server-side from `pin_type` (and `leaving_minutes`, capped at the 5/10/15/20 CHECK already in §2.2)
rather than trusting the client's value outright:

```sql
create or replace function public.derive_pin_expiry()
returns trigger language plpgsql security definer as $$
begin
  if new.pin_type = 'leaving_soon' then
    new.expires_at := now() + ((coalesce(new.leaving_minutes, 10) + 3) || ' minutes')::interval;
  elsif new.pin_type = 'open_spot' then
    new.expires_at := now() + interval '3 minutes';
  end if;
  -- enforcement_active / sweeper_passed / broken_meter keep their existing client-supplied
  -- value for now (ephemeralTTLSeconds(for:) — OQ-2 pending); revisit once OQ-2 is settled
  -- so both types get the same server-side-authoritative treatment in one pass.
  return new;
end; $$;

drop trigger if exists pins_derive_expiry on public.pins;
create trigger pins_derive_expiry
  before insert on public.pins
  for each row execute function public.derive_pin_expiry();
```

### §2.12 TTL expiry mechanism — client filter + a light hygiene sweep (not a full scheduled function)

**Recommendation: keep the shipped client-side filter as the primary mechanism, add a cheap
periodic sweep for hygiene.** Reasoning:

- The existing architecture already relies on `clientSideFilter` (`CommunityPinService.swift:682-704`)
  re-evaluated on every fetch/merge, exactly matching the prototype's own approach
  (`prototype.html:699`, `reports.filter(r => ... r.atMin + r.ttl > nm)` on every tick). A pin
  disappearing from a user's screen the moment `expires_at` passes does **not** require a server
  push — nothing needs to tell other clients "stop showing this," they already re-check the
  timestamp themselves on their own refresh/realtime cadence (45s poll + Realtime updates).
- A full scheduled-function expiry (e.g. `pg_cron` marking rows `resolved_at = now()` the instant
  they expire, so a Realtime DELETE-equivalent fires) buys *nothing* extra for map correctness — it
  only exists to bound query-result-set growth and keep the `pins_active_spatial_idx` partial index
  effective over time.
- `pg_cron`/`pg_net` are **already enabled and in production use** (`02d-ingest-cron.sql:17-18`) — so
  a light hygiene job is cheap to add, not a new capability to earn.

**Concretely:** add one `pg_cron` job, every 15 minutes, that does
`update pins set resolved_at = now() where expires_at < now() - interval '1 hour' and resolved_at is null`
(a 1-hour grace window past expiry, not immediate — avoids any race with a client mid-read). This is
pure data hygiene; it changes nothing about how the map behaves, since `clientSideFilter` already
hides these pins the instant `expires_at` passes, well before the sweep ever runs.

### §2.13 Test script

Kevin applies the migration; before he does, `@backend-data` ships a companion test script
(`scripts/test-community-2-schema.sh`, curl-against-PostgREST — same shape as the
`curl /auth/v1/signup` smoke already used to diagnose the anonymous-auth gap, HANDOFF 2026-06-06)
covering, at minimum: insert an `open_spot` pin anonymously (expect 403 — crowd insert requires
auth), insert one authenticated (expect 201, `expires_at` ≈ now+3m regardless of client-supplied
value), confirm-vote it (expect `profiles.reputation` +2 and `helped_count` +1 on the voter),
dispute-vote it 3× from 3 distinct auth sessions (expect `resolved_at` set), call `claim_pin` twice
(expect `true` then `false`), post a `leaving_soon` with `leaving_minutes=20` (expect `expires_at` ≈
now+23m, not client-controllable). **Never applied by an agent — this is Kevin's dashboard task,
same as every prior migration.**

---

## §3 Phase 1–4 — Scope Restated Against Actual Codebase Seams

### Phase 1 — Read-only network (zones + crew feed + map markers)

**Touches:** `Models/CommunityPin.swift`, `Services/CommunityPinService.swift`,
`Views/BrowseNavigationSheet.swift`, `Views/PinMarkerAnnotation.swift`, `ContentView.swift` (wiring
only). **New file:** `Services/ZoneMessageService.swift` (fetch + Realtime for `zone_messages`,
mirroring `CommunityPinService`'s own fetch/merge/Realtime shape rather than inventing a new
pattern), `Views/CrewFeedSection.swift`.

- `CommunityPin.swift`: add `.openSpot`/`.leavingSoon` enum cases + `OpenSpotMeta`/`LeavingSoonMeta`
  structs (mostly empty — the interesting fields, `position_fraction`/`leaving_minutes`/`claimed_by`,
  are first-class `pins` columns per §2.2, not meta) + three new stored properties on `CommunityPin`
  itself, following the exact pattern `startsAt`/`reportGroupId` used for their FT-15 additions.
- `CommunityPinService.swift`: widen Channel 2's `pin_type` filter list, `isChannel2Member`, and
  `RealtimeMergeGate.mergeablePinTypes` to include the two new types (each a 1-line change in 3
  places — the file's own comments already flag this as the "one-line addition in ONE place"
  extension seam). Add `zone_id` as a `RealtimeMergeGate` dimension (§1 delta) rather than a second
  channel.
- Crew feed: a new section inside `BrowseNavigationSheet.swift`'s pulled-up content, merging
  `ZoneMessageService`'s messages with `CommunityPinService.visiblePins` (filtered to the selected
  zone) into one newest-first list, matching `prototype.html:842-859`'s `feed` construction exactly
  (icon, ring color, title, sub, confirm/gone buttons on ephemeral non-own pins, claim button on
  `leaving_soon`).
- Zone chips: 3-way picker (Nolita/SoHo/LES) driving both services' `zone_id` query param.
- **Sheet detent:** FT-20 ships exactly two custom detents (peek + medium) by deliberate, twice-
  fought-for design (`BrowseNavigationSheet.swift:57-70`). The crew feed needs a third, taller state
  — this is an *addition* to the detent ladder (collapsed/half/full ≈ the prototype's own
  84/430/720 model, `prototype.html:834`), not a violation of Kevin's "no extra chrome at rest"
  ruling (§0f), since the feed only appears when the user pulls the sheet up, same as today's medium
  detent already does for search. **Still the highest-regression-risk change in this phase** — this
  file has 3 documented live-UI regressions in its history. Mandatory live-simulator smoke before
  merge, per the existing FT-20 gate.

**Acceptance criteria:**
- [ ] AC-P1.1 A crowd `open_spot`/`leaving_soon` pin inserted server-side appears on-map (correct
      ring color per §6 appendix) and in the crew feed within one Realtime tick, with zero pan.
- [ ] AC-P1.2 Switching zone chips changes both the feed contents and the map's crowd-pin fetch
      bounding filter; an empty zone shows an intentional empty state, not a blank/broken one.
- [ ] AC-P1.3 The resting sheet (peek + medium) is pixel-identical to today's FT-20 state with
      `communityEnabled = false` — zero regression to the shipped browse experience.
- [ ] AC-P1.4 Pulling to the new third detent with `communityEnabled = true` and zero community data
      in a zone renders an intentional "no reports yet" state, not an empty flash.
- [ ] AC-P1.5 Live-simulator smoke screenshot confirms no #31-class regression (toolbar, ASP banner,
      Park Until pill all still render) after this PR.

**Diff-size estimate:** ~500–700 lines. Under the 1.5k split trigger; no split required.

### Phase 2 — Contribution (report flow + identity sheet)

**Touches:** `Views/ReportSheet.swift` (extend 2→4 types), `Services/CommunityPinService.swift`
(payload additions), `WeParkApp.swift`/`SupabaseAuthService.swift` (profiles upsert on identity
save). **Reused as-is, zero changes:** `Views/BlockRestrictionReportSheet.swift` (the "Street
closure" tile routes straight to the existing `ActiveSheet.blockRestrictionReport(segments:)` case —
see §1 delta table; this is a superset of the design's closure flow, not a mismatch, given the
design's own copy already says "photo helps"). **New files:** `Views/SpotPlacementView.swift`,
`Views/IdentitySheet.swift`.

- **Report grid** goes from 2 tiles (enforcement, sweeper) to 4: add "Spot open" (routes to the new
  map-tap placement flow) and "Street closure" (routes to the existing `BlockRestrictionReportSheet`
  — no new code). Copy per `prototype.html:361-382`, verbatim.
- **"Confirm the street" step** for enforcement/sweeper: today `ReportSheet` takes its coordinate/
  segment as a given, no picker. Add a lightweight up-to-3-candidate list (this segment + opposite
  side + one neighbor each direction), reusing the **existing** `ParkConfirmView` "Wrong street?"
  35m-alternatives pattern (W5) rather than a new algorithm — extract the shared candidate-search
  helper if it isn't already a standalone function.
- **Spot placement** (`SpotPlacementView.swift`, net-new): map-tap → snap to nearest segment +
  `position_fraction` (reuses the W5 haversine segment search, extended to return a fraction along
  the segment, not just the nearest segment) → confirm card. **Scope cut recommendation:** ship the
  simpler "near {cross street}" / "mid-block" naming first (`prototype.html:824-830`'s `nearLabel`
  logic, trivial to port) and **defer the MapKit-POI-storefront-name lookup** ("in front of The Elk")
  to a fast-follow — it's an async network dependency for a cosmetic upgrade over an already-clear
  fallback, and this phase has enough net-new surface already.
- **Identity sheet** (`IdentitySheet.swift`, net-new): 8-avatar picker + handle text field, per
  `prototype.html:415-429`. **Behavioral clarification vs. the prototype's literal logic:** the
  prototype's `needIdentity()` re-shows the sheet on *every* contribution until a handle is actually
  set (`skipIdentity` never sets `state.handle`, so the gate never latches) — a straight port would
  re-prompt an anonymous poster on every single report. **Fix: gate on "has this device ever seen the
  identity sheet," a `UserDefaults` bool set the first time it's shown (regardless of pick-a-handle
  vs. skip), not on "does a `profiles.username` exist."** First-ever contribution shows it once;
  every contribution after that — anonymous or not — never re-shows it.
- Identity save (pick a handle): upserts a `profiles` row (`username`, `avatar`) — the reputation
  columns already exist server-side via §2.6's insert-on-conflict triggers, so this upsert only needs
  to set `username`/`avatar`, never `reputation` (client never writes its own rep, per the standing
  constraint).
- `insertCrowdPin` gains `positionFraction`/`leavingMinutes` optional parameters, included in the
  payload only when non-nil.

**Acceptance criteria:**
- [ ] AC-P2.1 Two devices: a report placed on one (any of the 4 types) appears correctly positioned
      (including `position_fraction` for `open_spot`) on the other within 2s.
- [ ] AC-P2.2 First-ever contribution on a fresh install shows the identity sheet exactly once,
      regardless of pick-a-handle vs. "post anonymously"; every subsequent contribution does not
      re-show it.
- [ ] AC-P2.3 "Street closure" opens the existing `BlockRestrictionReportSheet` unchanged — zero new
      code in that file, confirmed by diff.
- [ ] AC-P2.4 Submitting an `open_spot` report drops a pin snapped to the tapped curb position, not
      the segment midpoint, verified by comparing the map marker's rendered position to the tap
      coordinate.
- [ ] AC-P2.5 No copy anywhere in the new flow uses "avoid," "ticket," "fine," "evasion," or "dodge"
      (mirrors the existing `ReportSheet` AC-R17 convention).

**Diff-size estimate:** ~700–900 lines total. **Recommend a discretionary split** (not required by
the 1.5k rule, but prudent given `ReportSheet.swift`/`ContentView.swift` contention): **Phase 2a** =
confirm-the-street step + closure-tile wiring (~250–300 lines, almost entirely reuse); **Phase 2b** =
spot placement + identity sheet (~450–600 lines, the genuinely novel UI). 2a can ship fast and de-risk
the file touches before 2b's larger surface lands.

### Phase 3 — Trust loop (reactions, profile row, leaderboard)

**Touches:** `Views/PinDetailSheet.swift` (`ReactionsRow` — extend), `Views/CrewFeedSection.swift`
(profile row + leaderboard, both new to that file from Phase 1).

- `ReactionsRow` already renders confirm/dispute for `enforcement_active`/`sweeper_passed`
  (Tier 3 sub-PR #1). Extend the same component for `open_spot` (confirm/dispute, same as any other
  ephemeral crowd pin) and special-case `leaving_soon` (claim-only via `claim_pin`, no confirm/
  dispute row — matches `prototype.html:203-208`).
- Profile row: handle, tenure (`now() - profiles.created_at`, already available), accuracy
  (`accurate_report_count / total_report_count`, guard div-by-zero for a 0-report profile), helped
  count, rep — all backed by §2.5/§2.6's Phase 0 columns/triggers. No new schema in this phase.
- Weekly leaderboard: **recommend a simple v1**, not the design's implied persistent weekly-reset
  points table. Top 5 authors in the selected zone by count of `pins` they authored with
  `confirm_count > 0` in the trailing 7 days — a live query against existing columns, no new table.
  A true weekly-reset ledger (`reputation_events`) is a legitimate future ask but not one anything in
  the brief actually requires yet — see §5.

**Acceptance criteria:**
- [ ] AC-P3.1 Tapping "Still there" on any ephemeral crowd pin (including the two new types) awards
      the confirmer +2 rep and +1 helped-count, extends the pin's `expires_at` via the existing RPC,
      and the change is visible to a second device within one Realtime tick.
- [ ] AC-P3.2 Tapping "Gone" three times from three distinct sessions hides the pin (existing
      mechanism, §2.7) — no new decay code introduced.
- [ ] AC-P3.3 The profile row renders correctly for a brand-new anonymous poster with zero prior
      activity (0% accuracy shown as "—" or similar, not a divide-by-zero crash or "0%" false-negative).
- [ ] AC-P3.4 Leaderboard updates within one zone-switch — no stale cross-zone data shown.

**Diff-size estimate:** ~500–650 lines. Under 1.5k, no split needed.

### Phase 4 — Notifications + handoff

**Touches:** `Views/ParkedCarDetailView.swift` ("Hand your spot to the crew" section — **direct file
collision with PR #91**, see §4), `Services/NotificationScheduler.swift` (silent-push relevance
routing), `WeParkApp.swift` (APNs registration). **New:** `supabase/functions/send-community-push/index.ts`
(backend-data), the `pg_net` trigger invoking it (backend-data, folds into §2's migration file or a
small follow-up — Kevin's call whether Phase 0 stays single-PR or a slim Phase-4-schema PR is
acceptable given the working agreement's "ask before altering schema after Phase 0").

- Leaving-soon flow: 4-chip picker (5/10/15/20 min) + "Leaving in {mins} min — tell the crew" button
  in `ParkedCarDetailView`, per `prototype.html:323-332`. Calls `insertCrowdPin(type: .leavingSoon,
  positionFraction: <car's own segment fraction if known>, leavingMinutes: <picked>)`. `expires_at`
  is server-derived (§2.11) — the client sends `leaving_minutes`, never a raw expiry.
- Claim button: "I'm heading there" calls `claim_pin` RPC; `false` return shows "someone beat you to
  it, first come first served" rather than a generic error — this is the expected, race-safe outcome
  of §2.10's design, not a failure state.
- APNs pipeline (§2.9's architecture): device registers for remote notifications, uploads
  `(apns_token, zone_id)` to `device_push_tokens` (never lat/lng, never `segment_id` — only the
  already-public zone). New ephemeral crowd pin → `pg_net` trigger → Edge Function → silent push to
  every token in that zone → client compares `segment_id` against its own on-device
  `ParkedCar.segmentId` → surfaces a local notification via the **existing** `UNCalendarNotificationTrigger`/
  `UNUserNotificationCenter` machinery if (and only if) it matches. Zone-wide states (ASP, snow) keep
  using the existing top-banner surface, unchanged — this pipeline is for block-relevant pushes only,
  per rule 5.
- **New one-time Kevin setup, same shape as the iCloud-capability gap PR #91 hit:** APNs needs a
  token-based auth key (`.p8`) in App Store Connect + the `aps-environment` entitlement added to the
  Xcode project (currently absent — silent-failure risk identical to the iCloud capability miss:
  compiles, runs, never receives push, no error). Flag this explicitly before Phase 4 starts so it
  isn't discovered mid-build the way the iCloud capability was.

**Acceptance criteria:**
- [ ] AC-P4.1 "Leaving in 10 min" posts a `leaving_soon` pin at the car's exact parked position;
      `expires_at` is ~13 minutes out (server-derived, not client-controlled — verify by attempting
      to submit a tampered `expires_at` and confirming the server value wins).
- [ ] AC-P4.2 A second device tapping "I'm heading there" first wins the claim; a third device's
      attempt gets the "someone beat you to it" copy, not an error.
- [ ] AC-P4.3 On a physical device (push cannot be verified in Simulator) with `aps-environment`
      configured: an enforcement/sweeper pin inserted in a zone containing a device with a matching
      parked-car segment produces a **local, user-visible** notification; a pin in the same zone
      but a *different* segment produces no user-visible notification (silent push received, no
      surfaced alert) — proving the relevance gate works without the server ever learning the
      device's parked location.
- [ ] AC-P4.4 The Tuesday-ASP-morning sequence from the prototype's demo rail plays end-to-end
      on-device: reminder fires → block goes red → sweeper reported → confirm propagates → clear
      notification.

**Diff-size estimate:** iOS ~450–550 lines, backend (Edge Function + trigger) ~200–250 lines.
**Recommend a mandatory split**, not just a discretionary one: **Phase 4a** = leaving-soon UI + claim
button (fully Simulator-testable, ships and gets verified fast) — **Phase 4b** = the actual APNs
wiring (device registration, Edge Function, silent-push routing), which categorically cannot be
smoke-tested in Simulator and needs the one-time cert/entitlement setup above. Sequencing 4a before
4b also means the handoff feature (the part of Phase 4 Kevin explicitly reversed direction §4 to
ship) is live well before the push plumbing is ready, rather than both waiting on APNs setup together.

---

## §4 Sequencing vs. Current Reality

- **PR #91 (iCloud parked-car sync) is in flight, one build from done**, and touches
  `Services/ParkPinService.swift` + (implicitly) `Views/ParkedCarDetailView.swift`. Phase 4's
  leaving-soon UI lands in that exact same file. Per Kevin's instruction, **all iOS phases (1–4)
  wait for #91 to merge** — Phases 1–3 are technically file-disjoint from #91
  (`BrowseNavigationSheet.swift`/`ReportSheet.swift`/`CommunityPinService.swift`/`CommunityPin.swift`
  never touch `ParkPinService`/`ParkedCarDetailView`), so they *could* parallelize with #91 on pure
  file-contention grounds — noted for awareness, not overriding Kevin's stated sequencing.
- **Phase 0 (backend-data) starts now**, in parallel with #91 — zero iOS files touched. The
  `CommunityPin.swift` enum/meta additions in Phase 1 can also start before Kevin applies the Phase 0
  migration to production, exactly like PR #36 shipped the original typed-pin model before
  `02-pins-schema.sql` was live (HANDOFF 2026-06-02) — model-layer work has no runtime DB dependency.
- **Build numbering collision:** `docs/patrol-mode-feasibility-spec.md` (written 2026-08-24, two days
  before this brief) states *"patrol mode (either reading) is build 20+"* and treats the
  coverage-sweep smart-parking-route as the feature that will occupy build 20. This spec's brief
  (2026-08-26) also targets build 20 for community. **Recommend renumbering the smart-route feature
  to build 21+** when Kevin next picks it up — it's explicitly gated on the same drive-test as this
  feature and was already recommended to ship a "much smaller v1" later, so it isn't losing a slot it
  was about to use.
- **Drive-test gate applies to the flag-flip, not the merge.** Every phase can be built and merged to
  `main` behind `communityEnabled = false` regardless of drive-test status — Realtime is already
  shipped and load-bearing for the *existing* Tier 3 reporting loop (build 18, live externally
  today), so nothing in this spec introduces a new unproven dependency on that front. What's actually
  gated on Kevin's build-18 drive test (he's out of NYC 1–2 weeks) is **turning `communityEnabled` on
  for external TestFlight testers** — the realtime foundation needs to be proven solid on a moving
  car, on a live cell connection, before this much more realtime-dependent surface (crew feed,
  reactions, push) is the thing testers see first.
- **2-core VPS: 1–2 agents max.** Backend-data (Phase 0) should run solo first — nothing else is
  blocked *waiting* for it (per the model-layer precedent above), but it's the smallest, most
  self-contained piece and clears fastest. Once #91 merges, Phases 1 and 2 touch disjoint files
  (`BrowseNavigationSheet.swift` vs. `ReportSheet.swift`) and could run as two concurrent
  `ios-engineer` agents in separate worktrees if Kevin wants to spend both available slots on iOS at
  once — but note both still share `CommunityPinService.swift` and `CommunityPin.swift` (Phase 1 adds
  the two enum cases Phase 2's payload builder needs), so Phase 1's model-layer piece should land
  first even if the two phases otherwise run in parallel worktrees.
- **File-contention list**, ranked by how many phases in this spec touch them:
  1. `Services/CommunityPinService.swift` — Phases 1, 2, 3, 4 all touch it. The single most
     multi-phase file in this spec.
  2. `ContentView.swift` (3,723 lines) — already flagged repo-wide as the most contended file
     (HANDOFF 2026-08-13). Every phase does *some* wiring here (new `ActiveSheet` cases, sheet
     detent config, drive-mode guards).
  3. `Views/BrowseNavigationSheet.swift` — Phase 1's crew feed target, with a documented 3-incident
     regression history (§0f's own "do not restore the three-icon row" warning is evidence of how
     fought-over this file already is).
  4. `Views/ParkedCarDetailView.swift` — Phase 4 + PR #91, sequenced serially per the instruction
     above, not a parallelization opportunity.
  5. `Models/CommunityPin.swift` — Phases 1 and 3 both touch it, but additively (new cases, new
     properties) — low collision risk if Phase 1 lands first.

---

## §5 Out-of-Scope Follow-Ups

- **A true weekly-reset leaderboard ledger** (`reputation_events`, timestamped point-events that can
  be windowed to "this week" precisely). Phase 3 ships a live-query approximation instead (§3,
  Phase 3). Worth building properly only if the leaderboard turns out to matter to retention — no
  signal either way yet.
- **MapKit POI storefront naming** for `open_spot` placement ("in front of The Elk"). Deferred from
  Phase 2 to a fast-follow (§3, Phase 2) in favor of the simpler cross-street/mid-block fallback.
- **True NTA polygon zone geometry** (vs. this spec's bounding-box approximation, OQ-1). Revisit if
  boxes visibly misclassify real blocks once the feature is live.
- **`community-1.0-direction.md` §4 needs a superseded-marker edit** landing in the same commit as
  Phase 4 (the leaving-soon reversal) — flagged at the top of §1's delta table, repeating it here so
  it's on two checklists, not one that can be missed.
- **`02e-auto-resolve-trigger.sql`'s dormant TODO comment** (lines 75-77) should get a one-line
  pointer to §2.6 of this spec rather than being silently orphaned — small, but the kind of stale
  comment that costs a future agent real time re-deriving "wait, is this built or not."
- **Retiring the name "patrol mode"** — already recommended in `patrol-mode-feasibility-spec.md` §0
  and unrelated to this feature; repeating only to note that this spec introduces zero new use of
  that name, so there's nothing here to clean up on that front.

---

## §6 Appendix — Design Values Lifted Verbatim (for engineers + QA)

| Type | Color | Icon | TTL (design) | TTL (as recommended, pending OQ-2) | Source |
|---|---|---|---|---|---|
| `enforcement_active` | `#FF9F0A` | 🎫 | 45m | **5m** (shipped FT-1, unless OQ-2 flips it) | `prototype.html:792,1003`; `CommunityPinService.swift:1197-1206` |
| `sweeper_passed` | `#30D158` | 🧹 | 120m | **5m** (shipped FT-1, unless OQ-2 flips it) | same |
| `open_spot` | `#0A84FF` | `P` glyph | 3m | 3m (net-new, no conflict) | `prototype.html:795,1004` |
| `leaving_soon` | `#0A84FF` | 🚙 | stated minutes + 3 | stated minutes + 3 (net-new, no conflict) | `prototype.html:794,965` |
| `construction`/`filming` ("Street closure") | `#E8730D` | 🚧 / 🎬 | durable (no TTL) | durable, unchanged | `prototype.html:796-797,1003` |
| `block_note` | `#9BA1AF` | 📌 | durable | durable, unchanged | `prototype.html:798` |

Rep math (verbatim, `prototype.html:726-727,937,958,1040,1065-1066`): **+5** on report submit (to the
author), **+2** on confirm tap (to the confirmer, not the author), **+1** per chat message (to the
sender). All server-computed per §2.6 — the client never sets its own `reputation`.

Copy strings to port verbatim: report-type descriptions (`prototype.html:361-380`), leaving-soon
handoff card (`prototype.html:323-325`), claim confirmation (`prototype.html:207,1074`), identity
sheet (`prototype.html:418-419,427`).
