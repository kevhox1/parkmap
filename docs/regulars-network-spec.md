# Regulars — a trust network for the 5 people you actually know on your block

**Status:** SPEC — ready for `@backend-data` Phase 0 to start. iOS phases wait on Phase 0's schema
FILE (not its production apply) per the standing "model-layer has no runtime DB dependency"
precedent (`docs/community-2.0-reconciliation-spec.md` §4, PR #36 precedent). **Amended 2026-09-15**
with two new Kevin rulings (head-start default, Scheduled Departure) + one accepted-behavior ruling
(honest exclusivity) — see §0 items 6–8 and the inline `AMENDED 2026-09-15` call-outs throughout.
**Owner:** Tech Lead (this spec) → `@backend-data` (Phase 0/0b) → `@ios-engineer` (Phases 1–4, two of
which run in parallel — see §5) → `@designer` (QR/invite sheet + Regulars settings review) →
`@qa-verifier` per PR.
**Trigger:** Kevin, 2026-09-15: *"Creating some sort of friendship network capability... I know like
5 people on my block that park. I can write a message to them or specifically send a notification
that I'm moving my car or leaving rather than post to entire board."*
**Amendment trigger (same date, follow-up conversation):** Kevin — "2 minutes is nothing… I was
thinking 15 minutes haha" (head-start default, §0 decision 6) and "People also usually plan they're
leaving. So they could tell their Regulars, 'I'm out at 2pm today.'" (Scheduled Departure, §0
decision 7).
**Extends:** `supabase/03-community-2.0-schema.sql` (+ `04`/`05`/`06`), `supabase/functions/send-community-push/index.ts`,
`ios/WePark/WePark/Views/ParkedCarDetailView.swift`, `Views/SettingsView.swift`,
`Services/PushRegistrationService.swift` (read-only — no changes needed, see §3.3),
`Services/Constants.swift`, `WeParkApp.swift` (URL scheme handling).
**Does not touch:** `index.html`, the PWA, or anything in `docs/patrol-mode-feasibility-spec.md`'s
lane.

---

## Decisions Kevin has already ruled on (LOCKED — do not re-litigate)

1. **Feature name: "Regulars."** Locked 2026-09-15. Copy voice: "your Regulars," "Add a Regular,"
   "Hand your spot to your Regulars first." Runners-up considered and rejected: **Curbmates**,
   **Blockmates**, **Parkers** (too close to "parker," which already means every user of the app —
   confusing as a feature name), **Neighbors** (too close to the existing default-handle prefix
   `neighbor-XXXXXXXX`, `docs/community-2.0-reconciliation-spec.md` §2.6). "Crew" was never a
   candidate — it's already load-bearing for the zone-level public board ("crew feed," "crews form
   block by block") and reusing it would collapse two structurally different circles (public zone
   vs. private trust list) into one word. "Regulars" was chosen partly because it's already
   organically part of the app's voice — `IdentitySheet`'s own worked example for a decorative,
   non-unique handle is `MottStRegular` (`docs/community-2.0-reconciliation-spec.md` §2.5) — so the
   feature name and the identity system's own vocabulary reinforce each other for free.
2. **DM scope: NOT a chat app.** No threads, no inbox, no read receipts, no reply-in-app. Message
   capability = short, action-attached notes only. Kevin: *"I don't want this to be a chat app
   really."* §2 designs two narrow surfaces that satisfy his literal example ("moving my car in 10")
   without building conversation infrastructure.
3. **Car-pin visibility to Regulars: NO passive/standing visibility.** Regulars never see your
   parked car on their map day-to-day. The only location disclosure is the deliberate "I'm leaving"
   handoff, and even then it is not a new disclosure class — the pin was already going to become
   fully public per the 2026-08-24 standing rule the moment it posts (§2.1, community-2.0
   reconciliation spec). Kevin: *"the spot would be there anyway"* once handed off. §3.2 makes this
   the explicit privacy frame for the whole feature.
4. **Tier timing: user-configurable, per post.** Presets + a custom picker, mirroring the existing
   reminder-offset chip pattern (`ParkedCarDetailView.offsetChipsRow`,
   `ParkedCarDetailLogic.reminderChipDefinitions`). §2.1 specs the exact preset ladder. The default
   was an open decision at the time this line was written — **RESOLVED 2026-09-15, see decision 6
   below; §6 item 1 is no longer open.**
5. **Invite mechanism: both QR and share link**, same underlying token — QR is just a rendering of
   the link, not a second code path. §3.4.
6. **Tier head-start default: 15 minutes.** Amended 2026-09-15, supersedes §6's original open-decision
   recommendation of 2 minutes. Kevin: *"2 minutes is nothing… I was thinking 15 minutes haha."* This
   also reworks the preset ladder and custom bounds from a seconds-to-minutes mental model to a
   minutes-to-tens-of-minutes one — new numbers and reasoning in §2.1 (schema clamp) and §3.4 (UI
   chips). Closes §6's original open decision item 1.
7. **New v1 capability: Scheduled Departure.** Amended 2026-09-15. Kevin: *"People also usually plan
   they're leaving. So they could tell their Regulars, 'I'm out at 2pm today.'"* Extends Loop C (Quick
   Regulars Notice) with an optional future timestamp and a one-tap prompt that converts into the
   existing Tiered Handoff (Loop B) at the declared time. Full spec: §1.2a, §2.6, §3.5. This is
   additive scope discovered after the original 14-session estimate — session sizing grows, not
   silently absorbed; see §5's new S10b/S12b and §8's updated total.
8. **Honest exclusivity is accepted product behavior, not a bug.** Amended 2026-09-15. A head start
   that is as long as (or longer than) the departure window it's attached to can mean the zone board
   never sees a spot before it expires — that is the intended effect of "Regulars-first," not a defect
   to quietly fix. The composer must say so plainly before the user submits. See §1.2a and §3.4's new
   inline warning row for the required behavior and the copy constraints.

---

## §1 Product definition

### 1.1 Persona (the one Kevin described)

Kevin knows ~5 people who regularly park on his block. He wants two things a public zone board can't
give him: (a) a way to hand his spot to *them specifically* before strangers see it, and (b) a way to
send them a short heads-up ("moving my car in 10") without that heads-up ever touching the public
board at all. Both are low-frequency, transactional, courtesy actions between people who already know
each other in person — not a social feed, not a discovery surface, not a place to hang out. This is
consistent with the standing anti-engagement principle already recorded for the whole app
(`docs/product/synopsis.md`: *"not for fun — practical," notification is the product surface,
sessions last seconds*).

### 1.2 Core loops (v1)

**Loop A — Build your Regulars (once, in person).** Kevin taps "Add a Regular" in Settings, shows a
QR code (or sends a link) to a neighbor standing next to him; the neighbor scans it with the Camera
app, WePark opens, they confirm, done. Repeat 4 more times. This is a one-time, deliberate,
in-person act — the trust network grows exactly as fast as Kevin actually meets people, which is the
point (§3.4, and the orchestrator's original framing: "deliberate, in-person growth is a feature for
a trust network," not a bug).

**Loop B — Tiered Handoff (the flagship, daily-use loop).** Kevin is leaving. He opens "Hand your
spot to the crew" on the parked-car card exactly as he does today (this is the existing, shipped
`leaving_soon` flow — Community 2.0 Phase 4a, `docs/community-2.0-reconciliation-spec.md` §3 Phase
4). Two things are new: (1) a "give your Regulars a head start" chip row lets him choose how long his
5 neighbors get first crack before the pin's existing public visibility starts driving zone-wide
pushes; (2) an optional short note ("front spot, plug's a little loose") that only his Regulars ever
see. His 5 Regulars get an immediate, content-bearing push ("Kevin's leaving in 10 min, 15 min head
start — Mott St near Prince" — *updated 2026-09-15 to the new 15-min default, §0 decision 6; note
this exact pairing, a 15-min head start on a 10-min departure, is also the worked example for the
honest-exclusivity behavior in §1.2a*). Anyone else in the zone gets the existing relevance-gated silent push,
just after the head-start window instead of instantly. The pin itself was always going to be public
the moment it posted (decision 3, above) — Regulars just find out first and with more detail.

**Loop C — Quick Regulars Notice ("moving my car," no board post at all).** For the case Kevin
literally named that ISN'T a spot handoff — he's re-parking, feeding a meter, or just wants to give a
heads-up — a single-tap, canned-phrase-plus-optional-note action ("Moving my car" / "Back soon" +
free text, ≤140 chars) fires a one-way push to every Regular. It never creates a map pin, never
touches the public board, expires from any on-device history after ~1 hour, and has no reply
affordance. This satisfies "send a notification... rather than post to the entire board" literally,
without building a second location-sharing surface.

> **AMENDED 2026-09-15 — Loop C gains Scheduled Departure (§0 decision 7).** Kevin: *"People also
> usually plan they're leaving. So they could tell their Regulars, 'I'm out at 2pm today.'"* This is
> the same Quick Regulars Notice sheet, not a new surface: a 4th canned phrase, "I'm out at ___,"
> becomes schedulable for a future time, announces to Regulars immediately on post, and — at the
> declared time — prompts the poster (one tap, not automatic) to convert into a real Loop B Tiered
> Handoff. Full mechanism, no-show handling, and composer UX: §2.6 (schema) and §3.5 (client).

### 1.2a Honest exclusivity — accepted trade-off (ruling, 2026-09-15)

A head start is measured in the same unit as a departure window now (§0 decision 6), which makes an
uncomfortable interaction visible that the old seconds-vs-minutes mismatch mostly hid: **a head start
that is as long as, or longer than, the "leaving in" value it's attached to means the zone-wide sweep
(§2.8) cannot fire until after this `leaving_soon` pin has plausibly already expired.** Concretely — a
15-minute head start (the new default) on a 10-minute departure means the public zone board may never
see this spot at all before it's gone.

**Kevin's ruling: this is accepted, intended product behavior, not a bug to engineer around.**
Regulars-first is the entire premise of this feature (§1.1) — a trust network that only ever *matches*
the public board's timing would not be giving Kevin's 5 neighbors anything a stranger doesn't already
get. The one requirement this ruling imposes is **honesty in the composer**: a user choosing a
head-start/departure pairing that produces this effect must be told, plainly, before they submit —
not left to discover it later from a Regular who mentions the board never lit up. §3.4 specs the exact
inline warning and its copy constraints. This does not change §2.8's sweep mechanics, §2.9's push
contract, or any RLS posture above — it is a client-side UX requirement layered on top of behavior the
schema already produces correctly.

### 1.3 What v1 explicitly does NOT include

- **No DM threads, no inbox UI, no read receipts, no typing indicators, no reply-in-app.** Locked by
  Kevin (decision 2). If two Regulars want to talk, they text each other outside the app — WePark's
  job stops at "notify," not "converse."
- **No standing/live map visibility of a Regular's parked car.** Locked by Kevin (decision 3).
- **No friend discovery, search-by-handle, or contact-list import.** Growth is QR/link only, always
  initiated by someone who already knows the other person in person.
- **No group naming/multiple circles.** v1 is one flat "my Regulars" list per user, not a
  Facebook-style "groups" concept. (Kevin's own framing — "5 people on my block" — is a single flat
  list, not multiple named groups. Revisit only if real usage shows people want a work circle vs. a
  block circle, which is not in evidence yet.)
- **No in-app QR *scanner*.** The system Camera app already decodes QR codes into openable links on
  every supported iOS version; building a second scanner (AVFoundation capture session, a custom
  permission prompt, custom overlay UI) duplicates OS functionality for a flow that only ever happens
  once per relationship, in person, where the Camera app is already one swipe away. §3.4 revisits this
  only if real use shows the OS-Camera hop is annoying.
- **No moderation/report queue for Regulars content.** Block is the only lever (§2.3). A formal report
  flow for a 5-person trust network you built yourself is disproportionate scope for v1; if abuse
  between Regulars turns out to be a real pattern, add it then (§7).
- **No hard cap on Regulars count.** No schema enforcement; copy nudges toward "the people you
  actually know" without gating it. (Flagged as a soft design note, not blocking — see §6.)
- **New, 2026-09-15: Scheduled Departure is scoped to one canned phrase only.** Of the Quick Regulars
  Notice's four canned phrases (§3.5), only the new "I'm out at ___" is schedulable in v1. "Moving my
  car," "Back in a bit," and "Feeding the meter" stay send-now-only. The `regular_notices.scheduled_for`
  column (§2.6) doesn't preclude generalizing this later — it's a UI scope call, not a schema
  limitation — but nothing in Kevin's ask requests scheduling a meter-feeding heads-up, so it's not
  built now (§7).

---

## §2 Architecture — schema

One migration file, `supabase/07-regulars-schema.sql`, following the existing numbering convention.
**Kevin applies it to production by hand, exactly as with every prior migration — this spec produces
the file and a test script, never an applied schema.** Every table below follows this repo's two
proven RLS postures: (a) **deny-most, mutate-only-via-SECURITY-DEFINER-RPC** for anything that
creates a trust relationship (mirrors `claim_pin`'s single-writer-wins shape and `rate_limit_config`'s
deny-all-with-only-trigger-writers posture), and (b) **owner-may-read-own-rows**, remembering the S11
lesson verbatim: *RETURNING requires a SELECT policy* — every INSERT-able table below ships a
matching SELECT policy for at least the inserting role, closing the exact class of bug PR #100 fixed
for `device_push_tokens`.

### 2.1 `pins` — one new column, reusing the existing per-post-configurable-TTL precedent

> **AMENDED 2026-09-15 (§0 decision 6):** the clamp below is **60–3600** (1–60 minutes), replacing the
> original 15–300 (15 sec–5 min). Kevin: *"2 minutes is nothing… I was thinking 15 minutes haha."* The
> column keeps storing seconds (no rename — `regulars_head_start_seconds` is still accurate, just a
> wider range) so no existing reference to the column name needs to change. There is still no SQL-level
> `DEFAULT` — the 15-minute default (§0 decision 6) is a client-side pre-selected chip
> (`AppConstants`/§3.4), the same posture the original spec already used for every other head-start
> value: the server clamps whatever the client sends, it never supplies its own default.

```sql
alter table public.pins
  add column if not exists regulars_head_start_seconds integer
    check (regulars_head_start_seconds is null
           or regulars_head_start_seconds between 60 and 3600),
  add column if not exists zone_pushed_at timestamptz;

comment on column public.pins.regulars_head_start_seconds is
  'Only meaningful for leaving_soon. How long Regulars get an exclusive, content-bearing push before '
  'the existing zone-wide relevance-gated silent push fires for this pin. Null = no Regulars head '
  'start (poster has zero Regulars, or Regulars are disabled) — falls through to TODAY''S behavior '
  '(zone push fires immediately at insert), zero regression. Clamped server-side (60-3600, i.e. '
  '1-60 minutes, amended 2026-09-15 — see decision 6), never trust the client-supplied value outright '
  '— same posture as leaving_minutes (§2.2 of the Community 2.0 reconciliation spec). A value at or '
  'past this pin''s own leaving_minutes is valid and expected, not an error — see §1.2a''s honest-'
  'exclusivity ruling; the client warns before submit, the server does not reject it.';
comment on column public.pins.zone_pushed_at is
  'Stamped the moment the DELAYED zone-wide push fires for a leaving_soon pin with a head start '
  '(§2.6 sweep). Null for every other pin type/path — those still fire send-community-push '
  'synchronously at insert, completely unchanged.';
```

Nullable on every existing row — zero migration risk, matches the `position_fraction`/
`leaving_minutes`/`claimed_by` precedent exactly (community-2.0 reconciliation spec §2.2).

### 2.2 `regular_edges` — the trust graph itself

```sql
create table if not exists public.regular_edges (
  low_user_id  uuid not null references auth.users(id) on delete cascade,
  high_user_id uuid not null references auth.users(id) on delete cascade,
  created_at   timestamptz not null default now(),
  check (low_user_id < high_user_id),
  primary key (low_user_id, high_user_id)
);

alter table public.regular_edges enable row level security;

create policy regular_edges_select_own on public.regular_edges
  for select using (auth.uid() in (low_user_id, high_user_id));

-- Deliberately NO insert policy for the authenticated role. An edge is a trust claim about
-- ANOTHER account — a client must never be able to POST one directly (that would let anyone
-- assert a friendship with an arbitrary uid with no consent from the other side). The ONLY writer
-- is redeem_regular_invite() (§2.4), a SECURITY DEFINER function that proves BOTH sides consented
-- (one created the invite, the other redeemed it) before it ever inserts a row.

create policy regular_edges_delete_own on public.regular_edges
  for delete using (auth.uid() in (low_user_id, high_user_id));
-- Either party can end the relationship unilaterally — mirrors FT-2's "delete your own thing"
-- ethos (docs/ft2-delete-own-pin-spec.md), extended here to "delete your own relationship." No
-- update policy: edges are immutable facts, "unfriend" is delete, not edit.
```

Canonical `low/high` ordering (same idea as an undirected-graph edge list) keeps the relationship
single-row and makes "are these two Regulars" a trivial existence check from either direction,
without a symmetric pair of rows to keep in sync.

### 2.3 `regular_blocks` — directed, owner-only-visible

```sql
create table if not exists public.regular_blocks (
  user_id         uuid not null references auth.users(id) on delete cascade,
  blocked_user_id uuid not null references auth.users(id) on delete cascade,
  created_at      timestamptz not null default now(),
  check (user_id <> blocked_user_id),
  primary key (user_id, blocked_user_id)
);

alter table public.regular_blocks enable row level security;

create policy regular_blocks_select_own on public.regular_blocks
  for select using (user_id = auth.uid());
create policy regular_blocks_insert_own on public.regular_blocks
  for insert with check (user_id = auth.uid());
create policy regular_blocks_delete_own on public.regular_blocks
  for delete using (user_id = auth.uid());
-- Deliberately NO policy letting the blocked party see they were blocked — same convention as
-- most consumer apps, and it avoids retaliation against the blocker. Only the blocker's own
-- session can ever read/write their own block list.

create or replace function public.delete_regular_edge_on_block()
returns trigger language plpgsql security definer as $$
begin
  delete from public.regular_edges
  where (low_user_id = least(new.user_id, new.blocked_user_id)
     and high_user_id = greatest(new.user_id, new.blocked_user_id));
  return new;
end; $$;

drop trigger if exists regular_blocks_delete_edge on public.regular_blocks;
create trigger regular_blocks_delete_edge
  after insert on public.regular_blocks
  for each row execute function public.delete_regular_edge_on_block();
```

Blocking always severs an existing edge in the same transaction — a blocked party never has a
"friendship" left over to exploit.

### 2.4 `regular_invites` — short-lived, single-use tokens; QR and link are the SAME token

```sql
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
  'A single-use, 10-minute invite token. The row''s own id (a uuid) IS the token embedded in both '
  'the QR code and the share link (wepark://invite/<id>) — one code path renders two presentations, '
  'per Kevin''s "both QR and link" ruling, not two independent mechanisms.';

alter table public.regular_invites enable row level security;

create policy regular_invites_select_own on public.regular_invites
  for select using (created_by = auth.uid());
-- Deliberately NOT selectable by token for an arbitrary/anonymous reader — closes an enumeration
-- risk where guessing/listing tokens could leak inviter identity before redemption. The redeeming
-- side never reads this table directly; it only ever calls redeem_regular_invite() (below), which
-- looks the row up as the SECURITY DEFINER function owner, bypassing RLS.
create policy regular_invites_insert_own on public.regular_invites
  for insert with check (created_by = auth.uid());
create policy regular_invites_update_own on public.regular_invites
  for update using (created_by = auth.uid()) with check (created_by = auth.uid());
-- Lets the creator set revoked_at on their own still-open invite ("cancel" in the invite sheet).
-- No delete policy — invites are kept (revoked or expired) for the rate-limit accounting in §2.6.

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
```

`SELECT ... FOR UPDATE` + the `redeemed_at is null` predicate makes double-redemption race-safe —
same single-writer-wins shape as `claim_pin` (community-2.0 reconciliation spec §2.10), just
expressed as a row lock instead of a bare `UPDATE ... WHERE`, because this function needs to branch
(self-add, blocked) before deciding to write.

### 2.5 `pin_notes` — the ONLY free text attached to a public pin, and it is NOT public

```sql
create table if not exists public.pin_notes (
  pin_id     uuid primary key references public.pins(id) on delete cascade,
  author_id  uuid not null references auth.users(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 80),
  created_at timestamptz not null default now()
);

comment on table public.pin_notes is
  'The optional short note on a leaving_soon Tiered Handoff post ("front spot, plug''s a little '
  'loose"). Deliberately NOT a column on pins itself: pins_select_public already grants broad '
  'public read of every non-parked_car row (community-2.0 reconciliation spec §2.1/2.6-era standing '
  'privacy rule), so a note column added directly to pins would inherit that public-by-default '
  'visibility and defeat the entire point of a Regulars-only note. This side table gets its own, '
  'narrower SELECT policy instead.';

alter table public.pin_notes enable row level security;

create policy pin_notes_select_own_or_regular on public.pin_notes
  for select using (
    author_id = auth.uid()
    or exists (
      select 1 from public.regular_edges re
      where (re.low_user_id = pin_notes.author_id or re.high_user_id = pin_notes.author_id)
        and auth.uid() in (re.low_user_id, re.high_user_id)
    )
  );
create policy pin_notes_insert_own on public.pin_notes
  for insert with check (author_id = auth.uid());
create policy pin_notes_delete_own on public.pin_notes
  for delete using (author_id = auth.uid());

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

drop trigger if exists pin_notes_enforce_ownership on public.pin_notes;
create trigger pin_notes_enforce_ownership
  before insert on public.pin_notes
  for each row execute function public.enforce_pin_note_ownership();
```

This is the third visibility posture this app now has, worth naming explicitly against the standing
2026-08-24 rule (`HANDOFF.md` "STANDING PRIVACY RULE for pin visibility"): that rule enumerated
**PERSONAL-LOCATION (private, author-only)** and **COMMUNITY REPORTS (public)**. `pin_notes`
introduces a legitimate third posture — **REGULARS-VISIBLE** — content attached to an otherwise-public
pin, visible only to the author and their Regulars, never to a stranger browsing the same public pin.
This is a deliberate evolution of the standing rule (the rule's author didn't have a friends concept
to enumerate yet), not a violation of it — flagged for Kevin's awareness, not as an open question,
since the reasoning above is unambiguous.

### 2.6 `regular_notices` — the Quick Regulars Notice ("moving my car")

> **AMENDED 2026-09-15 — Scheduled Departure (§0 decision 7).** Adds one nullable column,
> `scheduled_for timestamptz`, plus a derived-`expires_at` trigger. **Reconciliation note for
> `@backend-data`/S1's QA (S2):** this spec agrees `regular_notices` is the right table for
> `scheduled_for` — do not move it. The one thing to verify against whatever diff S1 already wrote:
> `expires_at` must NOT stay a flat `now() + interval '60 minutes'` default once `scheduled_for` can be
> hours in the future. A notice scheduled at 9am for a 2pm departure would otherwise expire around
> 10am — hours before the departure it announces — because the original default anchors to
> `created_at`, not to the declared time. The trigger below anchors `expires_at` to
> `coalesce(scheduled_for, created_at) + 60 minutes` instead, so a scheduled notice stays valid through
> its own declared time plus the same one-hour grace window every other notice gets. **If S1's actual
> file already does this (or something equivalent), no correction needed — flag only if it doesn't.**

```sql
create table if not exists public.regular_notices (
  id            uuid primary key default gen_random_uuid(),
  sender_id     uuid not null references auth.users(id) on delete cascade,
  body          text not null check (char_length(body) between 1 and 140),
  created_at    timestamptz not null default now(),
  scheduled_for timestamptz,
  expires_at    timestamptz not null default (now() + interval '60 minutes'),
  check (scheduled_for is null or scheduled_for > created_at),
  check (scheduled_for is null or scheduled_for <= created_at + interval '24 hours')
);

comment on table public.regular_notices is
  'One-way, ephemeral broadcast to a sender''s whole Regulars list. NOT a message thread — no '
  'recipient-scoped read state, no reply, no per-recipient targeting in v1 (Kevin: "not a chat app '
  'really"). Visible to the sender and to every current Regular of the sender, until expires_at, then '
  'gone. Client composes body client-side from a canned-phrase prefix + optional free text before '
  'insert; the server stores and RLS-gates the final string, it does not care about its internal '
  'structure. scheduled_for (added 2026-09-15) is optional and, in v1, only ever set by the "I''m out '
  'at ___" canned phrase (§1.3, §3.5) — a future declared-departure time. The 24-hour CHECK keeps this '
  'a same-day/next-day tool, not a calendar feature (open for Kevin to confirm, §6 item 4).';

comment on column public.regular_notices.scheduled_for is
  'Null for an ordinary, send-now notice (unchanged v1 behavior). Non-null = "I''m out at ___" '
  '(Scheduled Departure, §0 decision 7): the notice announces to Regulars immediately on insert '
  '(unchanged trigger timing — only the CONTENT differs), while the client separately schedules a '
  'local, on-device reminder for this exact timestamp that prompts the poster to convert into a Loop '
  'B Tiered Handoff (§1.2a, §3.5). Never trust this value for anything privileged — it is a courtesy '
  'timestamp the poster chose, not a guarantee, and the no-show case (poster never converts) is '
  'expected and requires no cleanup (§3.5).';

alter table public.regular_notices enable row level security;

create policy regular_notices_select_own_or_regular on public.regular_notices
  for select using (
    sender_id = auth.uid()
    or exists (
      select 1 from public.regular_edges re
      where (re.low_user_id = regular_notices.sender_id or re.high_user_id = regular_notices.sender_id)
        and auth.uid() in (re.low_user_id, re.high_user_id)
    )
  );
create policy regular_notices_insert_own on public.regular_notices
  for insert with check (sender_id = auth.uid());
create policy regular_notices_delete_own on public.regular_notices
  for delete using (sender_id = auth.uid());
-- Delete-own lets a sender retract an accidental notice early, same "delete your own thing" ethos
-- as regular_edges/FT-2. No update policy — a notice is immutable once sent, matching "not a chat
-- app" (no editing a message after the fact either). This also means a scheduled notice cannot be
-- edited (change the time) once sent — the delete-then-resend pattern already covers "plans changed,"
-- no new UI needed (§3.5).

-- Added 2026-09-15: derive expires_at server-side, never trust whatever the client sent for it —
-- same "never trust the client-supplied value outright" posture as regulars_head_start_seconds (§2.1).
create or replace function public.regular_notices_derive_expiry()
returns trigger language plpgsql as $$
begin
  new.expires_at := coalesce(new.scheduled_for, new.created_at, now()) + interval '60 minutes';
  return new;
end; $$;

drop trigger if exists regular_notices_derive_expiry_trg on public.regular_notices;
create trigger regular_notices_derive_expiry_trg
  before insert on public.regular_notices
  for each row execute function public.regular_notices_derive_expiry();
```

### 2.7 Rate limiting — generalize the existing `rate_limit_config` pattern, don't invent a new one

```sql
insert into public.rate_limit_config (key, max_count, window_hours, max_rows)
values
  ('regular_invite', 20, 24, 60),
  ('regular_notice', 10, 1, 30)
on conflict (key) do nothing;

-- enforce_regular_invite_rate_limit() / enforce_regular_notice_rate_limit(): same shape as
-- enforce_ephemeral_report_rate_limit() (community-2.0 reconciliation spec §2.8) — count this
-- author's rows in the trailing window from an append-only log table, reject with 42501 over the
-- cap. @backend-data ports the existing pattern directly; no new shape to invent.
```

`regular_invite` (20/24h) is generous enough to onboard a whole block in one sitting without ever
being a plausible spam vector (redemption still requires a physical QR scan or an explicit tap on a
received link — an attacker gains nothing by generating unredeemed tokens). `regular_notice` (10/1h)
bounds the one genuinely spammable action in this spec — a compromised or bored account blasting its
own Regulars repeatedly.

### 2.8 Tiered push delay — reuse `send-community-push` unchanged; only the TIMING of its trigger changes for `leaving_soon`

No new Edge Function is needed for the "falls through to the zone board" half — it is the exact same
`send-community-push` function, unmodified. What changes is *when* it fires for `leaving_soon` pins:

```sql
-- 04-community-push-trigger.sql's existing trigger condition gains one predicate: it no longer
-- fires synchronously at INSERT time for leaving_soon (moved to the sweep below). Every other
-- ephemeral crowd type (enforcement_active, sweeper_passed, open_spot) is completely unaffected —
-- this is a one-line WHERE-clause change, not a rewrite.
-- (exact diff lands in the same migration file, referencing 04's existing trigger by name)

create or replace function public.sweep_leaving_soon_zone_push()
returns void language plpgsql security definer as $$
declare
  r record;
begin
  for r in
    select * from public.pins
    where pin_type = 'leaving_soon'
      and resolved_at is null
      and expires_at > now()
      and zone_pushed_at is null
      and created_at <= now() - make_interval(secs =>
            coalesce(regulars_head_start_seconds, 0))
  loop
    perform net.http_post(
      url := <same send-community-push URL as 04-community-push-trigger.sql>,
      headers := <same service-role auth header>,
      body := jsonb_build_object('pin', to_jsonb(r))
    );
    update public.pins set zone_pushed_at = now() where id = r.id;
  end loop;
end; $$;

select cron.schedule('sweep-leaving-soon-zone-push', '*/30 * * * * *',
  $$select public.sweep_leaving_soon_zone_push();$$);
```

A `regulars_head_start_seconds is null` pin (poster has zero Regulars) is picked up on the sweep's
very first pass (the `coalesce(..., 0)` makes the wait interval zero) — **zero regression for anyone
without Regulars**, they get exactly today's behavior, just riding a ≤30s poll instead of an instant
trigger. `pg_cron`/`pg_net` are already enabled and load-bearing in production
(`02d-ingest-cron.sql`), so this is retuning a proven primitive, not adopting a new one — flagged as
the spec's second-biggest technical risk regardless (§8), since nothing today runs a sub-minute cron
job and 30s-cadence correctness under load is unproven.

### 2.9 `send-regular-push` — the new Edge Function (the ONLY new one)

New sibling to `send-community-push`, same Deno/service-role-secret shape. Fires from a new trigger,
`pins_invoke_send_regular_push`, `AFTER INSERT ON pins WHEN (new.pin_type = 'leaving_soon')` — this
one fires immediately, unconditionally, same instant the pin is created (the whole point of "head
start"). Looks up `public.regular_edges` for the pin's `author_id`, resolves each Regular's device
token(s) straight from `device_push_tokens` **by `user_id`, not by `zone_id`** (Regulars want to hear
from a specific person regardless of which zone they're currently subscribed to — a friend visiting
from three blocks away should still hear "Kevin's leaving"), and sends a **visible, content-bearing**
alert (title/body, not silent/`content-available`).

**Why a visible payload is not a privacy exception, just a faster delivery of already-public data:**
per decision 3, a `leaving_soon` pin is unconditionally public the instant it posts — any stranger
browsing the zone board sees the exact same position and copy a Regular's push would show. Sending it
with visible content to consenting Regulars discloses *nothing beyond what a stranger can already see
by opening the app* — it just gets there faster and via a push instead of a browse. This is the
resolution to the tension the orchestrator's brief raised (ask #4): the server-never-learns-blockface
guarantee exists to protect **relevance-gating for strangers** (§2.9 of the community-2.0
reconciliation spec — the server must not learn which segment an arbitrary anonymous device cares
about); it was never a guarantee that *the pin's own content* is secret, because it isn't — it's a
deliberate, already-public disclosure. No new privacy posture is invented here; the existing one is
simply extended to a second, faster delivery channel for the same data.

**The push body never includes the `pin_notes` text.** `pins` and `pin_notes` are two separate
INSERT calls from the client (the note needs the pin's own generated id as a foreign key, so it
necessarily happens second) — baking the note into the trigger-fired push would race an insert that
hasn't happened yet. Instead the push is a lightweight attention-getter ("Kevin's leaving in 10 min —
15 min head start, Mott St near Prince" — *updated 2026-09-15 to the new default, §0 decision 6*); the
note (if any) is fetched live via `pin_notes`'s
Regulars-scoped SELECT the moment the recipient opens the app or taps the notification — matching
this app's existing philosophy of "the push's job is to get attention, the app's job is to show
content" (the same shape as the silent/on-device-resolved zone push).

**Payload contract:**

| Field | Zone-wide push (`send-community-push`, unchanged) | Regular push (`send-regular-push`, new) |
|---|---|---|
| APNs content | Silent (`content-available: 1`, no `alert`) | Visible `alert` (title + body) |
| Targeting | `device_push_tokens.zone_id = pin.zone_id` | `device_push_tokens.user_id in (regular ids)` |
| Relevance decision | On-device (client compares `segment_id`) | None needed — Regulars want to hear about this specific person regardless of segment |
| Location in payload | `segment_id` only (client resolves) | Same `segment_id`/position data — already public, no incremental disclosure |
| Note text | Never included (doesn't apply to non-`leaving_soon` types) | Never included (race-avoidance, §2.9 above); fetched on open |

Dead-token cleanup, batching/chunk caps, and the fail-open-guarantee lesson from S11 (Vault reads
inside the exception-safe block, not outside it) all carry over verbatim from `send-community-push` —
recommend factoring the raw APNs HTTP/2 send + dead-token-cleanup logic into a shared
`supabase/functions/_shared/apns.ts` module so both functions call the same hardened code instead of
forking it, closing the door on the two functions silently drifting apart over time.

### 2.10 Test script

Kevin applies the migration; before he does, `@backend-data` ships `scripts/test-regulars-schema.sh`
(same curl-against-PostgREST shape as `supabase/03-community-2.0-test.sh`), covering at minimum:
create an invite, redeem it from a second session (expect an edge to exist, visible from both
sides), redeem the same token again (expect `ok:false, expired_or_used`), redeem an invite from the
creator's own session (expect `cannot_add_self`), block then attempt redeem of a pre-existing invite
between the same two users (expect `blocked`), insert a `leaving_soon` pin with
`regulars_head_start_seconds=120` and confirm `zone_pushed_at` stays null until the sweep interval has
elapsed, attempt a `pin_notes` insert with a mismatched `author_id` (expect the ownership trigger to
reject it), confirm a non-Regular cannot `select` another user's `pin_notes`/`regular_notices` row
(expect zero rows, not a 403 — RLS filters, it doesn't error, matching the PostgREST-anon-role
behavior already documented as a Community 2.0 QA finding). **Never applied by an agent — this is
Kevin's dashboard task, same as every prior migration.**

> **AMENDED 2026-09-15 — two coverage items to add for the ruling-1/ruling-2 schema changes:** (1)
> confirm `regulars_head_start_seconds` rejects 59 and 3601 (just outside the new 60–3600 clamp,
> §2.1) while 60, 900 (15 min), and 3600 all succeed; (2) insert a `regular_notices` row with
> `scheduled_for` several hours out and confirm `expires_at` lands past `scheduled_for` (not past
> `created_at`) — this is the exact bug the §2.6 reconciliation note flags for S1's QA to check.

---

## §3 Architecture — client surfaces

### 3.1 Where the Regulars list lives

**Primary entry point: `SettingsView.swift`**, a new "Regulars" row (the file is small, 164 lines,
low contention — a safe place for a net-new entry point that doesn't fight any Community 2.0 phase
for file ownership). Tapping it opens `RegularsSettingsView.swift` (new): a list of current Regulars
(handle + avatar, mirroring the existing profile-row visual language from `CrewFeedSection`), a
remove/block action per row (swipe or a trailing button — bigger touch targets than a tiny "x," per
this repo's standing touch-target preference), and an "Add a Regular" button.

**Secondary surface: the leaving-soon card itself** (`ParkedCarDetailView.leavingSoonCard`) gains a
one-line "X Regulars will see this first" (or "Add Regulars to give someone a head start" if the list
is empty — an honest empty state, not a dead affordance) directly above the existing minute chips, so
the tiered-handoff behavior is visible exactly where it's used, not just buried in Settings.

### 3.2 Invite flow (QR + link, one token)

New `RegularInviteView.swift`, presented as a sheet from `RegularsSettingsView`'s "Add a Regular"
button:
- On appear: inserts one `regular_invites` row (`created_by = auth.uid()`), gets back the row's `id`.
- Renders a QR code from `wepark://invite/<id>` using `CoreImage.CIFilter.qrCodeGenerator` (a
  standard framework, zero new dependency) at a large, easy-to-scan size.
- Below the QR: the same URL as tappable text + a native `ShareLink(item: url)` for AirDrop/iMessage/
  copy — same token, same URL, just a second rendering, per decision 5.
- A visible "expires in 9:47" countdown (10-minute TTL, §2.4) and a "Cancel" button that sets
  `revoked_at` via the update-own policy.
- Polls (or subscribes via Realtime on the row's own `id` — `regular_invites` is a low-volume table,
  either works; recommend Realtime for parity with the rest of this app's live-update philosophy) for
  `redeemed_at` and flips to a success state, "✅ Dave joined your Regulars," the moment it fires.

**One-time Kevin setup, flagged explicitly (same silent-failure shape as the iCloud capability gap
and the `aps-environment` entitlement miss)**: `wepark://` is not currently a registered URL scheme
anywhere in `Info.plist` (`grep`-confirmed — no `CFBundleURLTypes` entry exists today). Register it
before this phase's live-device test, or the deep link silently does nothing when tapped (opens
Safari to a broken-looking address instead of the app, no crash, no error). Lower blast radius than
the APNs/iCloud misses (it fails obviously and immediately when tested, rather than silently
succeeding-but-empty), but still a manual Xcode project-settings step, not something that ships by
writing Swift alone.

**Redeem side:** `WeParkApp.swift` gains a small `.onOpenURL { url in ... }` handler that parses
`wepark://invite/<uuid>`, presents a lightweight confirm sheet ("Dave wants to add you as a Regular —
add them back?") rather than silently auto-redeeming on open (a user should see who they're about to
trust before the edge is created), then calls `redeem_regular_invite` on confirm.

**No in-app QR scanner in v1** (§1.3) — the system Camera app already produces an openable link from
any QR code; tapping the resulting banner opens WePark straight to the confirm sheet above.

### 3.3 Push registration — zero changes needed

`PushRegistrationService.swift` already uploads `(user_id, apns_token, environment, zone_id)` to
`device_push_tokens` at registration (Community 2.0 Phase 4b, S11/S12). Because `send-regular-push`
targets by `user_id` (§2.9), the exact same token row already serves both the zone-relevance push and
the Regulars push — **there is no new client-side registration surface to build.** This is worth
calling out explicitly since it removes an entire would-be work stream from this spec's iOS side.

### 3.4 Tiered handoff UI (`ParkedCarDetailView.swift`)

New chip row, "Give your Regulars a head start," directly below the existing 5/10/15/20-minute
leaving chips, following the SAME pattern as `ParkedCarDetailLogic.reminderChipDefinitions` +
`offsetChipsRow`:

> **AMENDED 2026-09-15 (§0 decision 6):** the preset ladder below (5/10/15/30 min, default 15,
> Custom 1–60 min) replaces the original 30 sec/1/2/5-min ladder entirely. Kevin: *"2 minutes is
> nothing… I was thinking 15 minutes haha."*

- Presets: **5 min / 10 min / 15 min (default) / 30 min**, plus a "Custom…" chip that opens a stepper
  (1 min–60 min, in 1-minute increments, matching the server's clamp in §2.1) rather than a free-text
  field — a stepper can't produce an invalid value, closing off a whole class of "what did they type"
  validation the server would otherwise have to defend against more defensively. Reasoning for the new
  numbers: the original ladder treated a head start as a brief courtesy buffer (seconds to a few
  minutes); Kevin's own framing treats it as a real errand-length window. 5 min is the new floor
  because anything shorter is close to indistinguishable from today's instant zone push and doesn't
  earn its own chip; 30 min is the practical ceiling for a *preset* (covers a coffee run or a quick
  stop, short enough that most real departures fit one of the four chips without opening Custom); 15
  min is the default because it's Kevin's own stated number. Custom's 60-minute ceiling covers a rare
  longer stop (an appointment) without pretending a head start can be open-ended — an unbounded head
  start stops being a "head start" and starts being a reservation, which would contradict the standing
  FCFS framing (§0 decision 3's "the spot would be there anyway" logic only holds if the head start is
  bounded).
- Row is hidden entirely if the user has zero Regulars (nothing to give a head start to) — the
  leaving-soon flow behaves exactly as it does today for a Regulars-less user, byte-identical.
- Below the chip row: an optional single-line text field, "Note for your Regulars (optional)," capped
  at 80 characters live (mirrors the existing 1000-char report-body cap pattern's live-counter UX),
  posted to `pin_notes` immediately after the `pins` insert succeeds (needs the generated `pin_id`).
- **New, 2026-09-15 — honest-exclusivity inline warning (§0 decision 8, §1.2a).** If the chosen head
  start (in minutes) is **greater than or equal to** the chosen "leaving in" value from the existing
  5/10/15/20-minute chips above this row, a one-line warning appears above the submit button before
  the user can post. This is a client-side computed check only — no new schema, no server rejection
  (§2.1's comment confirms the server accepts the value regardless). Copy family (final wording locked
  at build time by `@ios-engineer` + `@designer`): *"Only your Regulars will see this in time"* /
  *"Your Regulars get this spot first — the block might not see it before it's gone."* **Never** any of
  the following words in this copy or any variant of it: avoid, ticket, fine, evasion, dodge.
- Submit button copy updates to reflect both new choices when present: "Leaving in 10 min — 15 min
  head start for your Regulars" *(updated 2026-09-15 to the new default; this exact pairing also trips
  the exclusivity warning above — a deliberately realistic worked example, not a hypothetical)* (falls
  back to today's exact copy, verbatim, when no Regulars exist).

### 3.5 Quick Regulars Notice (`RegularNoticeView.swift`, new)

A small sheet (presented from the Regulars settings row, and optionally a shortcut near "Hand your
spot to the crew" since they're related actions a driver reaches for at the same moment): a short
picker of canned phrases ("Moving my car" / "Back in a bit" / "Feeding the meter") + an optional
free-text append (combined ≤140 chars, same live-counter UX as above), one big "Send to my Regulars"
button. No history view beyond "sent" confirmation — consistent with decision 2, this is fire-and-
forget, not a log a user browses later. (`regular_notices` rows exist server-side for 60 minutes
purely to be deliverable/readable by recipients who reopen the app shortly after receiving the push;
the client does not build a persistent "sent notices" screen in v1.)

> **AMENDED 2026-09-15 — Scheduled Departure (§0 decision 7).** Extends this exact sheet with a
> schedule mode. Kevin: *"People also usually plan they're leaving. So they could tell their Regulars,
> 'I'm out at 2pm today.'"*

**Schedule mode (new).** The canned-phrase picker gains a 4th option, **"I'm out at ___"** — the only
phrase schedulable in v1 (§1.3). Selecting it reveals:
- A native `DatePicker` (wheel or compact style — whichever gives the bigger touch target per this
  repo's standing preference), defaulting to the next quarter hour, constrained to **today, up to 24
  hours out** (matches §2.6's `scheduled_for` CHECK; §6 item 4 asks Kevin to confirm the 24h window is
  right). A native picker is chosen over a bespoke control for the same reason the head-start stepper
  (§3.4) rejected free text: it cannot produce an invalid value.
- The phrase live-fills with the picked time: "I'm out at 2:00 PM."
- The submit button relabels to "Schedule for 2:00 PM" (replacing "Send to my Regulars" only in this
  mode; the other three canned phrases keep the original button and behavior, unchanged).
- On success: "Your Regulars know you're leaving at 2:00 PM" plus a one-line explainer, "We'll remind
  you to hand off your spot when it's time" — sets the expectation that a second step (conversion,
  below) still needs the poster's own tap, it isn't automatic.

**On-post announce (immediate, to Regulars).** Composing a scheduled notice fires the same push to
every Regular that any other notice fires, right away, on insert — the body simply carries the future
time ("Kevin's out at 2:00 PM today"). No new push path or trigger timing change: this reuses whatever
insert-triggered push Loop C's original ask already requires for `regular_notices` (§1.2).

**T-minus reminder + one-tap conversion (poster-side only, new).** At compose time, the app also
schedules exactly **one local notification** (`UNUserNotificationCenter` — the same on-device substrate
already used for `ParkedCarDetailLogic.reminderChipDefinitions`'s parking reminders, so this is not a
new capability) to fire on the poster's own device **at the declared time itself, not some minutes
before it.** Recommendation is deliberately **both** the on-post announce above and this reminder, not
either/or — Regulars get advance notice (the point of telling them ahead), and the poster gets a nudge
so they don't have to remember their own plan. Firing the reminder early (a true "T-minus") was
considered and rejected: it risks a tap-through before the poster has actually started leaving, which
would start the head-start clock too soon and undercut the "I'm out at 2pm" premise (§1.2a); firing
exactly at the declared time keeps that phrase honest. A second, earlier nudge on top of this one was
also considered and rejected — this app's standing anti-engagement bias (§1.1, "notification is the
product surface") argues against stacking pushes for one plan.

Tapping the notification deep-links directly into the **existing** Tiered Handoff sheet
(`ParkedCarDetailView.leavingSoonCard`, §3.4) for the user's currently-parked car, pre-filled with the
15-minute default head-start chip (or the user's last-used value) and the note field pre-filled from
the notice's free text, if any. **This is a one-tap prompt, not an automatic post** — the user still
taps Submit. Two deliberate reasons full automation was rejected: (1) the car may no longer be where
the app last recorded it (already moved, already left) by the declared time, and an unconfirmed
auto-post risks publishing stale or wrong information to the whole zone board, not just Regulars — a
materially worse failure than a missed notification; (2) routing through the real composer means the
conversion inherits §3.4's new exclusivity warning for free — a scheduled departure that lands on a
short "leaving in" value gets the same honest inline warning as any manually-composed Tiered Handoff
post, with zero extra plumbing to build it twice.

**No-show handling — nothing dangles.** If the poster ignores or dismisses the reminder, no pin is
ever created: there is no server-side timeout, no "pending handoff" row, and no schema state that
needs cleanup. The `regular_notices` row itself simply expires on its own already-ephemeral schedule
(§2.6's `expires_at`, now correctly anchored past `scheduled_for` rather than past `created_at`) and
disappears exactly like every other notice. If the poster's plans change before the declared time, the
existing delete-own policy (§2.6) already lets them retract the notice early — no new UI needed for
that either, since editing a scheduled time was never in scope (§2.6's "immutable once sent" note
applies here too).

**Defensive case:** if the parked-car record is already gone by the time the reminder fires (deleted,
expired), the deep link falls back to a plain "You don't have an active parked car right now" state
instead of opening a broken or empty sheet.

### 3.6 `AppConstants.regularsEnabled` — same playbook as `communityEnabled`, guard tests included

```swift
/// Regulars network (docs/regulars-network-spec.md). Ships dark (`false`) through its build
/// phases, exactly like communityEnabled did for Community 2.0 — see that flag's own doc comment
/// for the full "why a compile-time flag, why guard tests" rationale; this one is a direct copy of
/// the playbook, not a new pattern.
static let regularsEnabled = false
```

Every phase pre-declares its guard-test names UP FRONT (the community-2.0 roadmap's own retro notes
that its 4 guard tests were discovered incrementally and had to be "reconciled by name" at the flip —
this spec avoids repeating that surprise):

- `testRegularsEnabled_defaultsFalse`
- `testRegularsSettingsRow_hidden_whenDisabled` (or the equivalent default-parameter test for
  whatever gates the Settings row's visibility)
- `testLeavingSoonCard_headStartRow_hidden_whenRegularsDisabled`
- `testAppConstants_regularsHeadStartRange_matchesServerClamp` (a pure-function test asserting the
  client's stepper bounds, **60–3600 seconds (amended 2026-09-15 — was 15–300)**, match §2.1's CHECK
  constraint literally, so the two can never silently drift)

> **AMENDED 2026-09-15 — two more guard tests, seeded for the same "known checklist, not a discovery
> pass" reason as the original four:**
> - `testAppConstants_regularsHeadStartDefault_is15Minutes` (locks the new default, §0 decision 6, so
>   it can't silently drift back toward the original 2-minute recommendation)
> - `testRegularNoticeScheduleMode_hidden_whenRegularsDisabled` (Scheduled Departure's schedule toggle
>   follows the same dark-ship gating every other Regulars surface uses)

These are seeded now so the eventual flip PR has a known, named checklist instead of an
after-the-fact discovery pass.

---

## §4 Anti-abuse — what's genuinely new vs. what's already covered

- **Invite spam:** bounded by `regular_invite`'s rate limit (§2.7); redemption still requires a
  physical scan/tap, so unredeemed invites are inert.
- **Notice spam:** bounded by `regular_notice`'s rate limit (§2.7).
- **Reputation farming via friend rings** (the orchestrator's ask #5): the existing
  `award_confirm_reputation` trigger (community-2.0 reconciliation spec §2.6) already awards +2 to
  ANY confirming account regardless of any relationship to the pin's author — **two colluding
  anonymous accounts can already farm this today, with zero Regulars edge required.** Regulars makes
  colluding pairs *faster and more reliable* at finding each other's pins first (the tiered push is
  exactly that), but does not raise the per-pin ceiling: `reputation_award_log`'s
  once-ever-per-(pin, voter) constraint (§2.6 of the reconciliation spec) still caps the payout at
  exactly +2 regardless of how quickly or reliably the confirm happens. **Recommendation: no schema
  change for v1** — the marginal risk this feature adds is speed/reliability, not magnitude, and
  building a "your Regulars' confirms don't count" exclusion pre-emptively (for an unconfirmed
  problem) repeats a pattern this repo has explicitly declined before (see the reconciliation spec's
  own deferral of a full `reputation_events` ledger, §5). **Do** add this to Kevin's post-launch
  watch-list: if leaderboard data ever shows reputation concentrated in 2-node cliques with a
  Regulars edge between them, that's the trigger to revisit, not a hypothetical now.
- **Blocking is unilateral and silent** (§2.3) — a blocked party is never notified, cannot re-add via
  any invite link they already hold (the RPC checks blocks on every redemption attempt, not just at
  invite-creation time), and any live edge is severed immediately.
- **Lost-identity risk is inherited, not created.** WePark's anonymous-auth model means a reinstall
  can cost a user their whole Regulars list with no account to sign back into — the same standing
  risk already recorded for report history (`HANDOFF.md`, 2026-08-20, "the anonymous identity is
  load-bearing for strangers"), but it stings more here because a 5-person hand-built trust list is
  harder to reconstruct than report history. Not something this spec fixes (the fix is real accounts,
  a much larger, unrelated change) — flagged as an honest, inherited limitation (§8).

---

## §5 Work streams — sizing and parallelization

Session unit matches the Community 2.0 precedent: one focused ~2–4h block driving one coherent,
QA-able PR (`docs/community-2.0-roadmap.md`, "What a session means").

| # | Stream | Owner | Depends on | Can run parallel with |
|---|---|---|---|---|
| S1a | Core schema: `regular_edges`, `regular_invites`, `regular_blocks`, `redeem_regular_invite` RPC, block→edge-delete trigger | `@backend-data` | — (starts now) | S1b can be the same or a following session; both are one migration file in practice, split here only for review size |
| S1b | `pin_notes`, `regular_notices` (+ **`scheduled_for`/derived-expiry trigger, amended 2026-09-15, §2.6**), `pins` columns (§2.1, **60–3600 clamp, amended 2026-09-15**), rate-limit rows (§2.7), the leaving_soon push-timing change + sweep function/cron job (§2.8) | `@backend-data` | S1a (same file target) | — |
| S2 | QA on S1a+S1b (schema) — **amended 2026-09-15: also verify the §2.6 `expires_at` derivation and the new 60–3600 clamp edges, per §2.10's added coverage items** | `@qa-verifier` | S1a+S1b | — |
| S3 | `send-regular-push` Edge Function + `_shared/apns.ts` extraction + new insert trigger | `@backend-data` | S1a/S1b FILE (not applied) | S5 (iOS model layer) — different codebases entirely |
| S4 | QA on S3 | `@qa-verifier` | S3 | — |
| S5 | iOS model/service layer: `Models/Regular.swift` (RegularEdge/RegularInvite/PinNote/RegularNotice), `Services/RegularsService.swift`, `AppConstants.regularsEnabled` + the now-6 guard tests (§3.6, amended 2026-09-15). Zero UI. | `@ios-engineer` | S1a/S1b FILE (not applied) | S3/S4 (different codebases) |
| S6 | QA on S5 | `@qa-verifier` | S5 | — |
| S7 | iOS UI: `RegularsSettingsView.swift`, `RegularInviteView.swift` (QR + `ShareLink`), `WeParkApp.swift` `.onOpenURL`, `Info.plist` URL scheme (Kevin's one-time step), `SettingsView.swift` row wiring | `@ios-engineer` | S5, S3/S4 (needs `send-regular-push` deployed for end-to-end invite testing, though the invite flow itself has no push dependency — can build against S5 alone and defer the live-push half of its gate to S13) | S9 (file-disjoint: touches `RegularsSettingsView`/`RegularInviteView`/`SettingsView`, never `ParkedCarDetailView`) |
| S8 | QA on S7 (+ Kevin's Info.plist step + a live two-device QR-scan-and-redeem smoke) | `@qa-verifier` | S7 | — |
| S9 | iOS UI: `ParkedCarDetailView.swift` head-start chip row + custom stepper + optional note field (§3.4). **Amended 2026-09-15: scope grew** — reworked preset ladder (5/10/15/30 min + Custom 1–60), plus the new honest-exclusivity inline warning. Still one session; the growth fit inside the existing ~2–4h unit, no split needed. | `@ios-engineer` | S5 | **S7/S8 and S10 — this is the parallel-execution seam Kevin explicitly asked for**: S9 touches `ParkedCarDetailView.swift` only, S7 touches Settings/Invite files only, S10 touches a brand-new file only. Three disjoint diffs, one shared dependency (S5), safe to run as up to three concurrent worktrees once S5 merges. |
| S10 | iOS UI: `RegularNoticeView.swift` (Quick Regulars Notice, §3.5) + entry point wiring. **Amended 2026-09-15: stays scoped to send-now only** — Scheduled Departure's schedule mode is broken out into S10b below rather than grown in place, so this session doesn't blow past the ~2–4h unit and the three-way parallel batch below stays clean. | `@ios-engineer` | S5 | S7, S9 (see above) |
| S10b | **New, 2026-09-15 (§0 decision 7).** iOS UI: Scheduled Departure — `RegularNoticeView.swift` schedule mode (4th canned phrase, time picker, "Schedule for ___" button), local-notification scheduling for the T-0 poster reminder, deep link into `ParkedCarDetailView`'s existing Tiered Handoff sheet pre-filled for one-tap conversion, "no active parked car" fallback state (§3.5) | `@ios-engineer` | S9 AND S10 (needs both merged — reuses S9's composer as the conversion target, S10's sheet as the scheduling surface) | This is the point the S7/S9/S10 parallel batch converges back into serial — S10b cannot start until both land. Safe to run alongside S11/S12 (QA on the now-merged S9/S10), since those touch no shared files with S10b. |
| S11 | QA on S9 | `@qa-verifier` | S9 | S12 |
| S12 | QA on S10 | `@qa-verifier` | S10 | S11 |
| S12b | **New, 2026-09-15.** QA on S10b — including the no-show case (dismiss the T-0 reminder; confirm zero pin created, zero orphaned row, and the `regular_notices` row still expires on its own schedule) and the "parked car already gone" fallback. Local-notification-only, no physical-device push needed — **can run on Simulator**, unlike S13. | `@qa-verifier` | S10b | — |
| S13 | Physical-device push verification: friend-targeted visible push arrives immediately; zone-wide fallback push arrives only after the configured head start on a control device; custom head-start value round-trips server-clamped; `pin_notes` visible only to a Regular, invisible (RLS-filtered, not erroring) to a non-Regular control device on the same pin | `@ios-engineer` + Kevin ceremony | S3/S4 deployed, S9/S11 merged | — |
| S14 | Flag flip: `regularsEnabled = true`, adjust the now-6 named guard tests (§3.6) to launched-world assertions, one small PR | `@ios-engineer` | Everything above (including S10b/S12b) + Kevin's field-confidence gate (§8) | — |

**Designer touchpoint:** `RegularInviteView`'s QR/link layout and `RegularsSettingsView`'s list —
one review pass, can happen any time after S7's first draft, does not block engineering (mirrors the
FT-20 sheet-detent review pattern from Community 2.0).

**Kevin's ceremonies, called out explicitly (none skippable, none an agent's to perform):** apply
`07-regulars-schema.sql` to production after S2's QA clears (dashboard paste, same two-step shape as
every prior migration); register `wepark://` in `Info.plist` before S8's live gate; deploy
`send-regular-push` + confirm the `sweep-leaving-soon-zone-push` cron job is running after S3/S4
clears (same secrets already exist from S11 — no new APNs credential ceremony expected, only a new
function deploy + `pg_cron` schedule); S13's two-physical-device push verification (cannot be
Simulator-tested, same class as S11/S12 in Community 2.0).

---

## §6 Open decisions for Kevin (genuinely remaining — the five from the original ask are locked, §0)

1. ~~**Default head-start preset.**~~ **RESOLVED 2026-09-15 — see §0 decision 6.** Default is 15
   minutes; preset ladder is 5/10/15/30 min + Custom (1–60 min). Kevin: *"2 minutes is nothing… I was
   thinking 15 minutes haha."* Original recommendation kept below, unedited, for the audit trail —
   treat it as historical, not current:
   > Recommendation: **2 minutes.** Reasoning: long enough that a
   > Regular with their phone in a pocket has a real chance to see the push and tap through before it's
   > moot, short enough that the "first come, first served" ethos toward the wider zone board (the
   > copy Kevin already shipped verbatim: "Spots can't be held") isn't meaningfully eroded for everyone
   > else. 30 seconds is likely too short to matter in practice; 5 minutes risks feeling like Regulars
   > *are* a reservation, which directly contradicts the existing FCFS framing.
2. **Soft guidance on Regulars-list size.** No schema cap is proposed (§1.3) — worth a one-line
   design decision on whether the invite/settings copy should gently nudge toward "this works best
   with the 3–8 people you actually see" or say nothing at all. Low-stakes, does not block any
   session above; can be decided at the `@designer` review in S7/S8.
3. **Should the Quick Regulars Notice canned-phrase list be exactly the three proposed in §3.5, or
   does Kevin want different/more presets?** Low-stakes, does not block schema or service-layer work;
   can be finalized alongside S9/S10's build. (Note: the new 4th, "I'm out at ___," is now locked by
   §0 decision 7 — this item is only about the original three.)
4. **New, 2026-09-15 — Scheduled Departure's 24-hour scheduling horizon.** §2.6/§3.5 cap how far ahead
   a departure can be scheduled at 24 hours — long enough for "I'm out at 2pm today" or even
   tomorrow morning, short enough to stay a same-day/next-day tool rather than a calendar feature.
   Confirm 24h is right, versus e.g. 8h (same-day only) or 72h (long-weekend planning). Low-stakes —
   the CHECK constraint (§2.6) is a one-line change either way and does not block S1b starting.
5. **New, 2026-09-15 — exclusivity warning copy.** §1.2a/§3.4 lock the *behavior* (warn when head
   start ≥ leaving-in value) but not the *exact wording* — final copy is `@ios-engineer` +
   `@designer`'s call at build time, within the banned-word list already given (§3.4). Flagging only so
   Kevin sees a real draft before S9 ships, not because the decision is blocked on him.

---

## §7 Out-of-scope follow-ups

- **Real DM threads.** If usage ever shows Kevin's Regulars actually want back-and-forth conversation
  (not just one-way notices), the natural extension is a `regular_id`-scoped table structurally
  similar to `zone_messages`'s own `segment_id` extension (`community-2.0-reconciliation-spec.md`
  §2.4) — but nothing in evidence today justifies building it, and Kevin has explicitly ruled against
  it for v1.
- **In-app QR scanner.** Deferred per §1.3 — revisit only if the Camera-app hop proves annoying in
  real use.
- **Multiple named Regulars groups** (e.g., "my block" vs. "my building"). Not requested, no evidence
  needed yet; the flat-list model in §2.2 doesn't preclude adding a `label` column to `regular_edges`
  later without a breaking migration.
- **Formal report/moderation queue for Regulars content.** Block is the only lever in v1 (§1.3); add
  a report path only if abuse between people who already know each other in person turns out to be a
  real pattern, which is not the expected failure mode for a trust network this small.
- **A hard cap on Regulars-list size.** No evidence it's needed; §6 item 2 covers the soft-copy
  version of this question.
- **Excluding Regulars' confirms from reputation math.** Explicitly deferred, not forgotten — §4's
  watch-list item, revisit only with real leaderboard evidence.
- **Universal-link-based invites** (vs. this spec's custom `wepark://` scheme). Would need an Apple
  App Site Association file hosted on a domain WePark controls — real infra for a flow that's
  primarily used co-present via QR anyway. Revisit only if link-sharing (not QR) turns out to be the
  dominant path in practice.
- **New, 2026-09-15: scheduling the other three canned phrases.** "Moving my car," "Back in a bit,"
  and "Feeding the meter" stay send-now-only in v1 (§1.3) — `scheduled_for` (§2.6) doesn't preclude
  generalizing this, but nothing in Kevin's ask requests a scheduled meter-feed reminder.
- **New, 2026-09-15: a management/edit UI for a pending scheduled departure.** v1 relies entirely on
  the existing delete-own policy (§2.6) — if plans change, delete and resend rather than edit-in-place.
  Revisit only if that pattern proves annoying in real use.
- **New, 2026-09-15: server-side automatic conversion** (skip the one-tap prompt, auto-post the Tiered
  Handoff at the declared time). Explicitly rejected for v1, not just unbuilt — §3.5 gives the two
  reasons (stale-location risk, losing the free exclusivity-warning re-entry into the real composer).
  Revisit only if real usage shows the one-tap prompt itself is the friction point, which is not in
  evidence yet.

---

## §8 Feasibility verdict

**FEASIBLE, and structurally similar in size to a single mid-sized Community 2.0 phase pair, not a
second Community 2.0.** Every hard primitive this feature needs already exists and is proven in
production: targeted per-token push delivery (`send-community-push`'s existing shape, just re-aimed
by `user_id` instead of `zone_id`), a race-safe single-writer-wins RPC pattern (`claim_pin`), a
proven deny-most/SECURITY-DEFINER-RPC RLS posture, a proven rate-limit table, and a proven
compile-time-flag-plus-guard-tests dark-ship playbook. The genuinely new primitives are bounded: one
new small Edge Function, one sub-minute cron job (the one piece of infra with no precedent at this
cadence — see risk below), and a URL-scheme deep link (a well-trodden iOS pattern this codebase
simply hasn't used yet).

> **AMENDED 2026-09-15 — Scheduled Departure (§0 decision 7) adds two sessions, S10b + S12b (§5).**
> This is additive scope Kevin asked for in a follow-up conversation after the original estimate
> landed, not a sign the original 14-session count was wrong or scope creep discovered mid-build —
> flagging it explicitly rather than quietly absorbing it into S9/S10's existing sizing (see the
> "amended" notes on both rows in §5's table for why a straight scope-add there was rejected in favor
> of a new session). **Updated total: 16 core sessions, +2 buffer = 18 sessions.**

**Total: ~14 sessions, +2 buffer (the same historical rate this repo's own QA-pass-2 frequency
justifies) = 16 sessions.** *(Original estimate — superseded by the amendment above. Kept for the
record, not because it's still current.)*

**Biggest risk — NOT technical: verifiability requires a second real, cooperating human.** Every
other feature in this app is meaningfully testable by Kevin alone (a solo device can post a report, a
solo device can browse a zone board). Regulars is valueless and untestable below two willing
participants who complete an in-person QR exchange — S8 and S13's live gates structurally cannot be
solo-Kevin-on-two-simulators the way most of Community 2.0's two-device ACs were (that project's own
AC-P2.1 needed a full extra session, S12, specifically because Kevin's Mac couldn't run two device
targets at once — this feature has that same structural bottleneck baked into TWO gates instead of
one, and needs an actual second person, not just a second device). Recommend Kevin plan S8/S13
around an actual neighbor or a second phone from day one, rather than discovering the two-device
constraint the way Community 2.0 did. *(Disambiguation note, 2026-09-15: the "S12" in this paragraph
is Community 2.0's own session from that project's roadmap, not this spec's S12/S12b — this spec's
S12b is the Scheduled Departure QA session added in §5, and is Simulator-testable, not a physical-
device gate like S8/S13.)*

**Second risk, technical: the 30-second `pg_cron` sweep (§2.8) has no precedent in this codebase.**
The existing hygiene sweep runs every 15 minutes; nothing today runs sub-minute. Recommend S3/S4
include an explicit load/correctness check (does a 30s cadence reliably keep up, does a `pins` table
scan at that frequency show up as a measurable cost) before this ships to more than Kevin's own
build.

---

## Appendix — file touch map (for `@qa-verifier` and future contention planning)

New files: `supabase/07-regulars-schema.sql`, `scripts/test-regulars-schema.sh`,
`supabase/functions/send-regular-push/index.ts`, `supabase/functions/_shared/apns.ts` (extracted),
`ios/WePark/WePark/Models/Regular.swift`, `Services/RegularsService.swift`,
`Views/RegularsSettingsView.swift`, `Views/RegularInviteView.swift`, `Views/RegularNoticeView.swift`.

Extended files: `supabase/04-community-push-trigger.sql` (one-predicate change),
`ios/WePark/WePark/Services/Constants.swift` (+`regularsEnabled`), `Views/SettingsView.swift`
(+1 row), `Views/ParkedCarDetailView.swift` (+head-start row, +note field — the file Community 2.0
Phase 4a/S10 and S13c already own; expect the usual careful-diff treatment that file gets),
`WeParkApp.swift` (+`.onOpenURL`), `Info.plist` (+`CFBundleURLTypes`, Kevin's manual step),
`ContentView.swift` (wiring only — new `ActiveSheet` cases, same additive pattern every Community 2.0
phase already used there).

Untouched, verified: `Services/PushRegistrationService.swift` (§3.3 — no changes needed),
`index.html`, `ios/**` anywhere else, `supabase/01`–`06` (read, not modified — `06`'s zone data is
irrelevant to a user-graph feature).

**Amended 2026-09-15 — Scheduled Departure adds zero new files.** `RegularNoticeView.swift` (already
listed above) grows to include schedule mode (§3.5); the one-tap conversion prompt deep-links into the
already-listed `ParkedCarDetailView.swift`. The only new backend surface is inside
`07-regulars-schema.sql` itself (the `scheduled_for` column + its derive-expiry trigger, §2.6) — no new
migration file, no new Edge Function, no new cron job (the T-0 poster reminder is a local
`UNUserNotificationCenter` schedule, client-only, §3.5).

## Amendment 2026-09-21 — push copy must be street-accurate (Kevin's ruling)

Kevin rejected zone-level push copy ("I think 'Nolita' is too open. This must be street dependent
or at least when I click the notification it should take me to the location that the regular
logged they are leaving from"). Ruling implemented as BOTH halves:

1. **Street label in the visible copy — via author-supplied label, not server geocoding.** The
   posting client already renders the human street label at handoff time (the My Car sheet's own
   "MOTT ST — West side · between PRINCE ST and SPRING ST" resolution). Amend DRAFT migration 07
   (unapplied — free to amend): `pins` gains nullable `street_label text` with a server-side
   length cap (CHECK, ~80 chars) and the same column-privilege posture as other client-writable
   columns; the client writes it at leaving_soon insert. `send-regular-push` prefers
   `street_label` in the alert body when present, falling back to `zones.name`. The label is
   disclosed ONLY via the Regulars push + pin detail (same consensual disclosure class as the
   handoff itself — §2.9 reasoning unchanged). No Notification Service Extension, no server
   geocoding — the device that knows the street tells the server the string.
2. **Tap-through deep-link (the "at least" floor).** Tapping the Regulars push routes to the pin's
   location on the map (payload already carries `pin_id`/`segment_id`/coords) — lands in the S13
   push-integration session's scope; named there explicitly.

Sizing: absorbed into existing sessions (07 amendment + function change = one small backend
session; client label-write joins the S9/handoff UI session; deep-link joins S13). No new
sessions.
