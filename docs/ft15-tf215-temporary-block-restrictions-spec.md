# FT-15 / TF2-15 — Temporary Block-Scoped Restrictions (shared primitive)

**Feature:** A crowd-reported, block-scoped, time-windowed restriction overlay — one new primitive that
serves two field-testing findings: **FT-15** (film-shoot placard → "no parking" closure) and **TF2-15**
(construction blocking a legally-metered block). "Build once, use twice" per Kevin's own framing in the
FT-15 log entry.
**Owner:** Tech Lead (this spec) → `@backend-data` (schema) + `@ios-engineer` (report UI + render +
consumption), in parallel per §10.
**Created:** 2026-08-11.
**Status:** SPEC — awaiting Kevin review. This is a **large** feature (new table, new Storage bucket, new
multi-select map interaction, a third pin-fetch channel, an extension to the #31-sensitive
`MapViewRepresentable` overlay layer). Sizing note in §11: treat this as **multiple engineering
sessions**, not one PR. I've cut real scope to keep phase 1 shippable — see §11 and §15.
**Extends:** `docs/typed-pin-schema-spec.md` (§3 two-axis model, §4.1 `pin_type` enum, §10 iOS models,
§12 work-stream pattern) — this spec does **not** replace it, only adds columns/tables/UI on top.
**Related:** `docs/field-testing-log.md` FT-15 (top of "Round 4") and TF2-15 ("TF2 Round 3" section).
Reuses lessons from `docs/qa/ft14-join-drop-investigation.md` (PR #68, merged) — see §4.

---

## Read this first — decisions Kevin should confirm before engineering starts

Full reasoning for each is in §13. All are resolved with a recommendation, so engineering is **not
blocked** on an answer unless marked 🔴.

1. **Extent picker = map tap-select, not typed cross-streets.** Recommend the user taps the actual
   affected blockfaces on the map (reusing the already-rendered segment geometry) rather than typing or
   picking cross-street names. This sidesteps the FT-14 naming-inconsistency problem entirely instead of
   re-solving it on-device. See §4.
2. **Rendering = existing marker pattern, not a new polyline layer, for phase 1.** "Overlay, not recolor"
   is satisfied by reusing the proven `PinMarkerAnnotation` marker (Tier 1's existing filming/special-event
   marker) at each affected block. A dashed/hatched polyline treatment across the block geometry is
   possible but is new `MapViewRepresentable` overlay surface — deferred. See §9.1. 🔴 confirm this reading
   of "overlay" is acceptable, or if you want the polyline treatment in phase 1.
3. **Photo evidence is captured in phase 1, but never shown to other users.** It's stored for
   provenance/moderation only (author + service-role read), because the placard in Kevin's own photo has a
   real name and cell number on it. No OCR/redaction exists yet to safely show it publicly. See §7.
4. **Offline queueing is cut from phase 1.** Photo + form require a live connection to submit; a failed
   submit shows a retry button (same pattern as today's `ReportSheet`). A persistent background-upload
   queue is real, useful work — but it's sized as its own follow-up, not bundled into an already-large
   feature. See §8 and §15.
5. **The stale film-permit dataset investigation is a separate, non-blocking ticket** for `@backend-data`
   — not part of this spec's engineering. See §14.

---

## 1. Problem & User Story

Kevin, standing at a pole on E 2nd St, photographed a laminated NYPD **"NO PARKING — FILM SHOOT"**
placard: posted Wed 8/12 @ 12pm; vehicles must be moved by Thu 8/13/26; shoot time 6AM; production "North
Six"; location manager "Matthew, 347-996-8207." It covers **E 2nd St between 3rd Ave and 1st Ave** — two
blocks, both curbs, **four blockfaces**.

The baked tile data (legal signage) is correct and unaffected — this is a *temporary reality on top of*
the legal signage, exactly the same shape of problem TF2-15 already named for Bowery construction: "the
Bowery stretch isn't parkable at all right now (construction), regardless of the metered signage the tiles
describe" (`docs/field-testing-log.md` TF2-15 entry). Two different real-world events, same underlying
gap: **WePark has no way to say "this specific stretch of curb is temporarily unusable, starting at time X,
independent of what the sign says."**

**User story:** "I see a paper sign posted on a pole. I take a photo, tell the app which blocks and curbs
it covers and when it starts/ends, and every affected block reflects that — visibly, honestly labeled as
community-reported — until it expires or a neighbor disputes it."

**Why now:** The typed-pin schema already anticipated this (`docs/typed-pin-schema-spec.md` AC-S5,
§4.1 `filming`/`construction` types) and the Tier 1 ingestion pipeline for `filming` already ships
(`upsert_filming_pin` + `ingest-film-permits` cron, `supabase/02d-ingest-cron.sql`). But I verified today
(2026-08-11) against NYC Open Data directly: the film-permit dataset (`tg4x-b46p`) has a newest
`startdatetime` of **2026-05-12** across all 18,501 rows, and **zero** rows ever match E 2nd St. That
pipeline is ~3 months stale and is the wrong primary signal for this case — it was never going to catch
Kevin's shoot. The crowd path is not a nice-to-have alongside open data; for `filming` it's currently the
*only* signal that will ever fire on real-world timelines. Construction permits are a separate open dataset
never wired at all (TF2-15 direction: "ingest NYC street-construction permits... + crowd reports for what
permits miss" — the crowd half is 100% of what exists today).

---

## 2. Scope — In / Out

### In (this spec)
- One new crowd-sourced ingestion path: photo capture + confirm-form → N `pins` rows (one per affected
  blockface) sharing a `report_group_id`, for `pin_type in (filming, construction)`, `source = 'crowd'`.
- Block resolution via direct map tap-select (§4) — no free-text or cross-street-name matching.
- Explicit `starts_at` / kept-as-is `expires_at` time window, with type-specific defaults and hard
  expiry ceilings (§5).
- Photo evidence storage, access-restricted, no PII surfaced in any UI (§7).
- Consumption/render: map marker per affected block (reuse existing pattern) + a "Temporary restriction"
  banner in `BlockDetailView` / `ParkedCarDetailView` when the viewed segment is covered by an active
  report (§9).
- Extending the existing confirm/dispute + auto-resolve mechanics to cover this new
  session/durable-lifespan crowd case (today's auto-resolve trigger only covers `ephemeral` — a real gap
  for this exact feature, see §6).
- A basic per-author rate limit (§6).
- TF2-15 reuses the identical primitive for `construction` — same UI, same schema, different type/defaults
  (§9.3). This spec is the TF2-15 spec too; no separate doc.

### Out (deferred — see §14 for the full list with rationale)
- Vision/OCR extraction of sign fields (Kevin's own phase-2 scoping — this spec leaves the seam, doesn't
  build it).
- Persistent offline submission queue (§8, §15).
- Cross-street-name/typed-picker extent selection (§4 — the map-tap design makes this unnecessary for v1;
  flagged as a possible future accessibility improvement, not required).
- Showing the evidence photo to any user other than the author.
- Tier 1 open-data ingestion of NYC's construction-permit dataset (the "hybrid" half of TF2-15's own
  roadmap note) — separate `@backend-data` investigation.
- Fixing/repointing the stale film-permit cron — separate, non-blocking (§14).
- Author-side "extend this construction report" UI for windows that outlast the hard ceiling.
- A dashed/hatched polyline overlay treatment (vs. the marker approach) — flagged, not built, in §9.1.

---

## 3. Architecture

### 3.1 Codebases touched
- **Supabase** (`@backend-data`): new migration `supabase/02f-block-scoped-restrictions.sql` — two new
  nullable columns on `pins`, a new `pin_evidence` table + RLS, a new private Storage bucket, an extension
  to `auto_resolve_on_dispute`, a new rate-limit trigger, one new index. No changes to existing tables'
  shape in a breaking way — everything is additive.
- **iOS** (`@ios-engineer`): new model fields, a new report-flow view, a new map multi-select interaction
  (touches `MapViewRepresentable.swift` — the #31-sensitive file, additively), a third `CommunityPinService`
  fetch channel, and consumption surfaces in `PinDetailSheet` / `BlockDetailView` / `ParkedCarDetailView`.
- **PWA**: **not touched, and nothing here breaks it.** The PWA does not read the `pins` table at all today
  (`docs/typed-pin-schema-spec.md` §11: "informational only... PWA does not need to consume community pins
  for MVP"). All schema changes are additive columns/tables — zero risk to the live PWA.

### 3.2 New schema surface (sketch — `@backend-data` finalizes)

```sql
-- supabase/02f-block-scoped-restrictions.sql (sketch)

-- 1. Two new nullable columns on the existing pins table.
alter table public.pins
  add column if not exists starts_at        timestamptz,   -- null = active immediately (today's implicit behavior)
  add column if not exists report_group_id  uuid;           -- links N blockface rows from one user report

create index if not exists pins_report_group_id_idx
  on public.pins(report_group_id) where report_group_id is not null;

-- 2. Photo evidence — NEVER exposed via pins_with_author or any anon-readable path.
create table if not exists public.pin_evidence (
  id               uuid primary key default gen_random_uuid(),
  pin_id           uuid not null references public.pins(id) on delete cascade,
  report_group_id  uuid,                 -- denorm: one photo can back all rows in a group
  storage_path     text not null,        -- path within the private 'pin-evidence' bucket
  uploaded_by      uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now()
);

alter table public.pin_evidence enable row level security;

-- Only the uploader can read their own evidence row (service_role bypasses for future moderation).
create policy pin_evidence_select_own on public.pin_evidence
  for select using (auth.uid() = uploaded_by);

create policy pin_evidence_insert_own on public.pin_evidence
  for insert with check (auth.uid() = uploaded_by);

-- Storage: private bucket, no anon/public read policy at all. Access only via
-- short-lived signed URLs requested by the uploader (or service-role tooling later).
-- insert into storage.buckets (id, name, public) values ('pin-evidence', 'pin-evidence', false);
```

**`segment_id` semantics diverge by type — documented, not silently overloaded.** Today's comment on
`pins.segment_id` (`supabase/02-pins-schema.sql:51`) says it's "the street|from|to key from tiles/index.json"
— a 3-part key, no side. For `pin_type in (filming, construction) AND report_group_id is not null`, this
spec defines `segment_id` as a **4-part blockface key**: `STREET|MIN(FROM,TO)|MAX(FROM,TO)|SIDE` (cross
streets sorted alphabetically so the key is direction-agnostic — see §4.2). This is safe because the only
existing writer of `segment_id` on `filming` pins is `upsert_filming_pin`, which **always writes `null`**
(`supabase/02d-ingest-cron.sql:56`) — there is no legacy 3-part-key data on `filming` rows to collide with.
`construction` pins have no existing writer at all today. All other pin types keep the existing 3-part (or
null) convention untouched.

**No RLS changes needed for the `pins` insert path.** `pins_insert_crowd` already allows any `pin_type`
as long as `source = 'crowd'` and `author_id = auth.uid()` (`supabase/02-pins-schema.sql:142-148`). Crowd
`filming`/`construction` rows satisfy this today, unmodified.

**No collision with the existing `filming` permit-dedup index.** `pins_filming_permit_id_uidx` is a partial
unique index on `(meta->>'permit_id') where pin_type='filming'` (`supabase/02b-pins-ingest-indexes.sql:9-11`).
Crowd reports from this spec never set `meta.permit_id` — Postgres unique indexes treat multiple `NULL`s
as non-conflicting, so any number of crowd `filming` rows coexist safely with the open-data dedup index.

### 3.3 Auto-resolve gap — a real fix needed for this feature specifically

`auto_resolve_on_dispute` (`supabase/02e-auto-resolve-trigger.sql:59-63`) only fires for
`lifespan = 'ephemeral' AND source = 'crowd'`. A block-scoped filming/construction report is `lifespan =
'session'` or `'durable'` — **today it has no dispute-driven resolution path at all.** A mistaken or
malicious "this block is closed" report currently only goes away via hard expiry, which for construction
(week-plus windows) is a long time to leave a wrong closure marker live. §6 extends this trigger's guard.

### 3.4 Data flow

```
User taps long-press → confirmationDialog gains a 3rd action:
  "Report closure (film shoot / construction)"
    → enters block-select mode on the main map (§4.2)
    → user taps 1..N blockfaces; "Both curbs" toggle auto-adds the opposite side
    → floating bar: "N blocks selected — Both curbs [x] — Continue"
    → BlockRestrictionReportSheet (new): camera capture (required) + type
      (Film shoot / Construction) + starts/ends pickers + notes
    → Submit:
        1. Upload photo → Storage 'pin-evidence' bucket, private path
        2. Insert pin_evidence row (storage_path, report_group_id)
        3. Insert N pins rows (one per selected blockface), same report_group_id,
           client-generated UUID, via existing insertCrowdPin-style POST (plain
           REST, no new RPC needed — batched as N sequential/concurrent inserts)

Read path (existing CommunityPinService.fetchPins, extended with a 3rd channel):
  Channel 1 (existing): source=open_data, pin_type in (filming, asp_suspended_today, special_event)
  Channel 2 (existing): source=crowd, lifespan=ephemeral, pin_type in (enforcement_active, sweeper_passed)
  Channel 3 (NEW):      source=crowd, pin_type in (filming, construction),
                         resolved_at is null, (expires_at is null OR expires_at > now)
  → merged into visiblePins, exactly like today

Render: PinMarkerAnnotation at each affected blockface's pin (existing marker code path, §9.1)
Consume: BlockDetailView / ParkedCarDetailView query visiblePins for a segment_id match
         against the viewed Segment's blockfaceKey (§9.2)
```

**Concrete gap this closes:** `CommunityPinService.buildOpenDataRequest` hardcodes `source=eq.open_data`
(`ios/WePark/WePark/Services/CommunityPinService.swift:446`); `buildCrowdEphemeralRequest` hardcodes
`lifespan=eq.ephemeral` (`ios/WePark/WePark/Services/CommunityPinService.swift:494`). **Neither existing
channel would ever return a `source=crowd, lifespan=session` row.** Without Channel 3, this entire feature
would silently insert rows the app never fetches. This is called out explicitly as AC-I8 / AC-R-fetch below
because it's the kind of gap that's easy to miss in review.

---

## 4. Block resolution — the core design problem

### 4.1 Why NOT cross-street pickers or typed text (the FT-14 lesson, applied by avoidance)

FT-14 (`docs/qa/ft14-join-drop-investigation.md`, merged PR #68) found NYC's *own* raw sign dataset spells
the same physical corner two different ways in different rows (`"LA GUARDIA PLACE"` vs `"LAGUARDIA
PLACE"`), and that even after the `osmName()`/`NYC_TO_OSM` fix, matching is still probabilistic
(alias tables, spacing-collision fallback, exact-match-gated). That normalizer lives at
**build time** (`build/preprocess.js`, Node, `@backend-data`) — it reconciles NYC's raw sign feed against
OSM geometry once, when tiles are built. It has no runtime iOS equivalent, and building a second,
on-device version of that same fuzzy-matching problem (to resolve a user's typed or picked "3rd Ave to 1st
Ave" against the *already-baked* segment `fromStreet`/`to` strings) would be reinventing exactly the class
of bug FT-14 just spent real effort fixing — except now live, on-device, without the offline QA pass FT-14
got.

**The way to avoid a second naming scheme entirely: don't derive block identity from names at all.** The
tile data for the user's current viewport is already loaded and already rendered as real, named,
side-tagged polylines on screen. Have the user **tap the actual segments** they mean. The block identity
comes directly from the `Segment` the user tapped — `street`, `fromStreet`, `to`, `side` are read verbatim
off the already-loaded object, not re-derived from any text the user typed or picked. There is no join, no
normalization, and no possibility of a spacing/alias mismatch, because both the write path (tap → read
`Segment` fields) and the read path (compare against the currently-viewed `Segment`'s own fields) run the
identical `Segment.blockfaceKey` computed property in the same binary — string equality only, by
construction.

This is also why cross-street pickers are a worse phase-1 choice on pure complexity grounds, independent of
the naming risk: "between 3rd Ave and 1st Ave" implies a street-topology ordering problem (which block is
adjacent to which along a named, non-numeric street) that the tile data does not currently encode as a
graph. Numbered avenues make it look easy (numeric ordering); it isn't easy in general.

### 4.2 Design: map tap-select, "Both curbs" toggle

1. Long-press on the map (existing entry point, `ios/WePark/WePark/Views/MapViewRepresentable.swift`'s
   `handleLongPress` chain / `ios/WePark/WePark/ContentView.swift:571` confirmationDialog) gains a third
   action alongside "Park my car here" / "Report enforcement or sweeper": **"Report closure (film shoot /
   construction)."**
2. Entering this mode does **not** open a sheet immediately. It puts the map into a **block-select mode**
   (same UI pattern class as `parkUntilMode` at `ContentView.swift:319` — a `@State` boolean flag that
   changes tap behavior and shows a bottom bar via `.safeAreaInset`).
3. In block-select mode, tapping any rendered blockface **toggles it into/out of** a
   `@State selectedBlockKeys: Set<String>` set, where the key is `Segment.blockfaceKey` (new pure computed
   property, §4.3). The tapped segment is added to a new `MapViewRepresentable` highlight overlay showing
   all currently-selected blocks (see §9.1 for the overlay mechanics — this is the one touch to the
   #31-sensitive file).
4. A **"Both curbs"** toggle (default **ON**, matching Kevin's own canonical case) — when on, tapping one
   side auto-adds the opposite side of the same blockface (same `street`/unordered `{fromStreet,to}`,
   different `side`), found by scanning currently-loaded segments for a match. When off, only the tapped
   side is added.
5. A floating bottom bar shows: `"2 blocks selected · Both curbs · Continue"` with a Cancel action.
   Tapping Continue presents `BlockRestrictionReportSheet` (new), pre-populated with a plain-text summary
   of the selection (e.g. "E 2nd St, 3rd Ave–1st Ave, both curbs (4 blockfaces)") built from the selected
   set, purely for user confirmation — not re-derived from names at submit time, just displayed.
6. **Constraint, stated explicitly:** this assumes the reporter is standing at/near the affected blocks
   (map already centered there, matching how Kevin actually used the feature — photographing the sign in
   place). Remote reporting (forwarding someone else's photo from across town) is out of scope; the photo
   requirement in decision #1 already implies presence.

### 4.3 `Segment.blockfaceKey` (new, pure, additive)

```swift
// Models/Segment.swift — new computed property, additive, no existing field touched.
extension Segment {
    /// Direction-agnostic blockface identity: STREET|MIN(FROM,TO)|MAX(FROM,TO)|SIDE, uppercase.
    /// Cross streets are alphabetically sorted so this key matches regardless of which physical
    /// direction a given Segment row happened to store `from`/`to` in — two Segment rows describing
    /// the same physical blockface (e.g. one per direction of a divided street's sub-segments) must
    /// still resolve to the same key.
    var blockfaceKey: String {
        let (lo, hi) = fromStreet <= to ? (fromStreet, to) : (to, fromStreet)
        return "\(street)|\(lo)|\(hi)|\(side)"
    }
}
```

This is the single source of truth used on both the write path (building `pins.segment_id` at insert time)
and the read path (matching a viewed `Segment` against `visiblePins` in §9.2) — no separate matching logic
exists anywhere else.

---

## 5. Time window model

### 5.1 Reuse `expires_at`, add `starts_at`

`expires_at` already exists and already means "when this pin stops being valid" for `session`/`ephemeral`
types (`docs/typed-pin-schema-spec.md` §8). This spec adds **`starts_at`** (nullable; `null` = active
immediately, matching every existing pin type's current behavior with zero migration risk to them). A
report's active window is `[starts_at ?? created_at, expires_at]`.

### 5.2 Kevin's own sign is the concrete test for "start but no end"

Re-reading the placard fields: "posted Wed 8/12 @ 12pm" is when the *sign itself* went up (not a
restriction time); "vehicles must be moved by Thu 8/13" is the actual restriction start; "shoot time 6AM"
narrows it further; there is **no end time printed on the sign at all** — exactly the common case named in
the brief. The confirm-form must therefore ask:
- **"Restriction starts"** — date+time picker, defaulting to today/tomorrow (per the boilerplate's own
  "posted max 24h in advance" convention — used only as a UX default range, not a hard validation rule,
  since it describes physical sign-posting practice, not a constraint on real-world restriction timing).
- **"Restriction ends (optional)"** — date+time picker, may be left blank.
- If left blank: `expires_at` defaults to `starts_at + <type default>` (below), clearly labeled in the UI
  ("We'll assume this ends in 24 hours unless you say otherwise — you can always report it again").

### 5.3 Per-type defaults and hard ceilings (recommendation — tune post-launch)

| pin_type | Default window (if end left blank) | Hard ceiling from `starts_at` | Rationale |
|---|---|---|---|
| `filming` | 24 hours | 7 days | Matches typical single-day permits; occasional multi-day shoots covered by the ceiling, not the default. |
| `construction` | 14 days | 90 days | Construction genuinely runs longer; TF2-15's Bowery case is exactly this. No auto-extension UI in phase 1 (§2 Out) — a report that's still accurate past 90 days needs a fresh report. |

The hard ceiling is enforced by a `before insert` check constraint or trigger on `pins`
(`expires_at <= coalesce(starts_at, created_at) + <ceiling per pin_type>`), not just a client-side default
— this is the literal "hard expiry" half of decision #2.

---

## 6. Trust / abuse

**What's already free:** RLS (`pins_insert_crowd`) already requires an authenticated, attributable
`author_id`; `pins_select_public` already makes these rows anonymous-readable (no change needed);
`profiles.reputation` already exists as a future lever (Phase 2e in HANDOFF.md backlog, not wired here).

**What this spec adds:**

1. **Extend `auto_resolve_on_dispute` to cover this case.** Today's guard
   (`supabase/02e-auto-resolve-trigger.sql:59-63`) is `lifespan = 'ephemeral' AND source = 'crowd'`.
   Extend to: `(lifespan = 'ephemeral' OR (lifespan in ('session','durable') AND pin_type in ('filming',
   'construction'))) AND source = 'crowd'`. Keep the same 3-dispute threshold — this is a scoped guard
   widening, not a new policy decision (Kevin already approved 3 disputes for the ephemeral case,
   `docs/tier3-auth-and-reactions-spec.md` OQ-2 A2). Without this, a disputed block-scoped report has no
   automatic resolution path at all until hard expiry (days to weeks).
2. **Rate limit.** A `before insert` trigger on `pins` rejecting a new `report_group_id` batch if the same
   `author_id` has created more than **3 block-scoped reports (distinct `report_group_id`s) in the last
   24 hours.** Bounds spam/gatekeeping without needing reputation scoring to exist yet.
3. **Cannot fan out beyond what the reporter explicitly selected.** No radius, no "nearby blocks
   inherit," no street-wide propagation — only the tapped blockface set gets rows. A malicious report is
   contained to exactly the blocks the reporter tapped.
4. **Cannot silently show "free."** Per decision #2, the render treatment is additive-only (§9.1) — a
   false report can wrongly mark a legally-open block as closed (annoying, disputable, self-limiting via
   #1 above), but it structurally **cannot** make a restricted block appear free, because the base signage
   polyline color is never touched by this pin type.
5. **No structured PII capture, by design.** The confirm-form intentionally has no "location manager
   name/phone" field even though the placard has one — see §7. If a user types it into free-text `notes`
   anyway, that's the same pre-existing risk surface every other `notes`-bearing pin type already has
   (`block_note`, etc.) — not a new problem introduced here, not specially mitigated here either.

---

## 7. Photo evidence & PII

**The concrete problem:** Kevin's own placard photo has a real name ("Matthew") and a real cell number
("347-996-8207") printed on it. "Attach the photo as evidence" (decision #1) and "do not surface PII in the
UI" (the brief) are in direct tension unless the photo's visibility is scoped narrowly.

**Resolution:** the photo is stored, but **never served to any user other than its uploader** in phase 1.

- New private Storage bucket `pin-evidence` (no public/anon read policy at all — see §3.2 sketch).
- New `pin_evidence` table, RLS `select`/`insert` restricted to `uploaded_by = auth.uid()`.
  `service_role` bypasses RLS for future moderation tooling (not built here).
- `pins_with_author` (the public view every client reads) is **not modified** — it never gains a
  `photo_url` column. If a UI affordance is wanted to show "Evidence photo attached ✓" to other users
  (a reasonable trust signal), that's a `count(pin_evidence) > 0` boolean computed server-side, never the
  photo bytes — **explicitly flagged as an out-of-scope follow-up**, not built in this pass, to keep phase
  1 minimal.
- The confirm-form has **no structured field for a location-manager name or phone number**, even though
  the sign the feature was designed around has one. There is no product reason to capture it, and every
  structured field is a UI surface someone could accidentally expose later. If phase-2 OCR eventually reads
  the sign, it must explicitly *exclude* those fields from its extraction, not merely from display — noted
  here so the phase-2 spec inherits this constraint rather than rediscovering it.
- Retention: no automatic deletion in phase 1 (volume is small — a handful of reports, not the whole
  sign corpus). A 90-day storage sweep is a reasonable follow-up once volume justifies it (§14).

---

## 8. Offline / poor-signal capture

**Addressed, but deliberately cut down for phase 1** (see §15 for why this is a scope cut, not an
oversight).

Phase 1 behavior: photo capture itself works fully offline (camera has no network dependency). **Submit**
requires connectivity. If the submit network call fails, the sheet shows the same inline error pattern
`ReportSheet` already uses (`ios/WePark/WePark/Views/ReportSheet.swift:243-248`, `submitError` + Retry) —
the photo and form state remain in the still-open sheet so the user can retry without re-entering anything,
but nothing survives an app kill or a sheet dismissal.

**Deferred, sized as its own follow-up:** a persistent `PendingBlockReportQueue` that (a) writes the photo
to local disk immediately at capture time (so it survives an app kill before upload), (b) queues the pins
insert + evidence upload as two independently-retriable operations, (c) flushes on a connectivity-restored
signal or app-foreground, mirroring the retry-loop shape `CommunityPinService`'s periodic refresh already
uses. This is real, valuable engineering — curbside cellular really is often poor — but it's a
self-contained unit of work that doesn't need to gate shipping the core primitive. Flagged as a named
follow-up in §14, not silently dropped.

---

## 9. Rendering & consumption

### 9.1 Render: reuse the existing marker, don't add a new polyline layer (recommended)

The existing rendering architecture is 5 `MKMultiPolyline` overlays grouped by `CurrentState` + 1
`selectedBlock` single-`MKPolyline` highlight overlay (`ios/WePark/WePark/Views/MapViewRepresentable.swift:20,71`,
`docs/ios-rendering-architecture-decision.md`). Tier 1 pins (`filming`, `special_event`) already render as
a distinct `PinMarkerAnnotation` — a circular SF-Symbol marker, tap-to-detail
(`ios/WePark/WePark/Views/MapViewRepresentable.swift:1342-1357`). This already satisfies "overlay, not
recolor" literally: the base polyline color is never touched; a marker sitting on top of the map is an
overlay by any reasonable reading.

**Recommendation:** phase 1 places one `PinMarkerAnnotation` per affected blockface's `pins` row (same
marker code path, `pin_type = filming` uses the existing purple `video.fill` glyph
(`ios/WePark/WePark/Views/PinDetailSheet.swift:216-228`); `construction` needs a new glyph/color — suggest
`hammer.fill` / a construction-orange, a one-line addition to the same switch). This requires **zero** new
`MapViewRepresentable` overlay code for the render step itself.

**What DOES touch `MapViewRepresentable.swift`:** the block-select **multi-tap highlight** during report
creation (§4.2 step 3) — a new small overlay type showing all currently-selected blocks, additive next to
(not replacing) the existing single-segment `selectedBlock` case. This is the one genuinely #31-sensitive
touch in this spec. Given this file's documented regression history (the W8.5c-polish revert saga in
HANDOFF.md, and the standing "spec-fidelity" + live-UI-smoke norms it produced), this work item **must**
follow the same discipline already established: additive-only overlay type, mutation via the
`CoordinatorActions` closure pattern (not inside `updateUIView`), and a mandatory live-UI-smoke screenshot
before merge — same gate every camera/overlay change has needed since.

A dashed/hatched polyline treatment across the actual blockface geometry (visually stronger than a marker)
is a legitimate future enhancement, explicitly **not** built here — flagged in decision #2 for Kevin to
weigh in on.

### 9.2 Consume: surface it where a car is actually parked

The highest-value consumption point is not the map marker — it's telling someone whose car is *already
parked on* an affected block. Extend `BlockDetailView` and `ParkedCarDetailView` (both already read
`Segment`) with a lookup: does any pin in `CommunityPinService.visiblePins` have `pin_type in (filming,
construction)`, `report_group_id != nil`, and `segment_id == viewedSegment.blockfaceKey`? If so, show a
banner: **"Temporary restriction reported: [Film shoot / Construction], [starts_at]–[expires_at]"** with a
tap-through to `PinDetailSheet` for full detail + confirm/dispute (reuses the existing `ReactionsRow`
pattern from `PinDetailSheet.swift:256-388` — no new voting UI needed, `lifespan in (session, durable)`
extends past today's `pin.lifespan == .ephemeral` gate at `PinDetailSheet.swift:55`, which needs a one-line
widen).

### 9.3 TF2-15 reuses the identical primitive — proving the abstraction

Everything above is written type-generically. TF2-15 (Bowery construction) uses:
- The **same** `BlockRestrictionReportSheet`, with `pin_type = .construction` selected instead of
  `.filming` (a top-level type picker in the sheet, same shape as `ReportSheet`'s existing
  `enforcementActive`/`sweeper` picker).
- The **same** map tap-select extent picker (§4.2) — a user standing on Bowery taps the blocks that are
  actually barricaded/impassable, not a name-derived span.
- The **same** `starts_at`/`expires_at` window, with construction's own longer defaults (§5.3).
- The **same** marker + `BlockDetailView` banner consumption path (§9.1–9.2) — the only difference is
  glyph/color and copy ("Under construction" vs. "Film shoot").
- The **same** trust/abuse extensions (§6).

The only TF2-15-specific work **not** covered by this spec is the *open-data* half of its own roadmap note
("ingest NYC street-construction permits as Tier 1 `construction` pins... + crowd reports for what permits
miss") — that's a Tier 1 ingestion pipeline (new Edge Function + cron, mirroring
`ingest-film-permits`/`upsert_filming_pin`), explicitly out of scope here (§2, §14).

---

## 10. Work Streams

| Stream | Owner | Files | Depends on | Parallel? |
|---|---|---|---|---|
| **A — Schema** | `@backend-data` | `supabase/02f-block-scoped-restrictions.sql` (new): `starts_at`/`report_group_id` columns, `pin_evidence` table + RLS, `pin-evidence` Storage bucket + policies, extended `auto_resolve_on_dispute`, rate-limit trigger, hard-ceiling constraint | This spec approved | Yes — parallel with B1 |
| **B1 — iOS models** | `@ios-engineer` | `Models/Segment.swift` (add `blockfaceKey`, additive), `Models/CommunityPin.swift` (add `startsAt` to `CommunityPin`; extend `FilmingMeta`/add `ConstructionMeta` fields per §5; add `hasEvidencePhoto: Bool`). **Note:** `PinDetailSheet.swift`'s AC-D20 comment ("`CommunityPin.swift` is NOT modified") was a diff-minimization discipline scoped to *that* PR, not a standing freeze — this spec deliberately extends the model, which is expected and fine. Fixture-based unit tests only, no DB dependency. | This spec approved | Yes — parallel with A |
| **B2 — Map multi-select + report sheet** | `@ios-engineer` | `ContentView.swift` (3rd confirmationDialog action, block-select mode state), `Views/MapViewRepresentable.swift` (new additive multi-segment highlight overlay, §9.1 — **requires live-UI-smoke before merge**), `Views/BlockRestrictionReportSheet.swift` (**new** — camera capture + type/time/notes form, separate file from `ReportSheet.swift` to avoid merge collision and because the interaction shape differs materially) | B1 | Serializes after B1 (needs `blockfaceKey`); can start stubbed against B1's interface before B1 fully lands |
| **B3 — Write path + evidence upload** | `@ios-engineer` | `Services/CommunityPinService.swift` (new `insertBlockScopedReport(...)`, batched N-row insert + evidence upload), new `Services/PinEvidenceUploader.swift` | A + B1 | Serializes after A (needs live schema to integration-test against) and B1 |
| **B4 — Third fetch channel + consumption** | `@ios-engineer` | `Services/CommunityPinService.swift` (new `buildCrowdBlockScopedRequest`, merged into `fetchPins`), `Views/PinDetailSheet.swift` (widen the `lifespan == .ephemeral` reactions gate; construction glyph/color; multi-blockface summary display), `Views/BlockDetailView.swift` + `Views/ParkedCarDetailView.swift` (new banner) | A + B1 | Serializes after A + B1; parallel with B2/B3 once B1 lands (different files) |
| **Designer review** | `@designer` | reads `BlockRestrictionReportSheet` UI + the new banner once B2/B4 have a working build | B2 + B4 first pass | Serial (standard lifecycle position) |
| **QA** | `@qa-verifier` | reads the diff cold across A + B1–B4 | All streams merged | Serial, per TEAM.md invariant |

**Parallel group 1 (start immediately):** A, B1.
**Parallel group 2 (after B1 lands):** B2, B4-fetch-channel-half can start against fixtures; B3 needs A live.
**File-overlap note:** B2 and B4 both touch `CommunityPinService.swift` in different methods — coordinate
or land B2's write-path additions and B4's fetch-channel addition as sequential small diffs to avoid a
merge fight, even though they're conceptually parallel.

---

## 11. Phasing

### Phase 1 (this spec, minimum shippable — handles Kevin's canonical E 2nd St case end to end)
- Multi-block, both-curbs map tap-select (§4) — **required**, this is the literal acceptance bar per the
  brief, not deferrable.
- Photo capture + attach as evidence (decision #1) — **required**.
- `starts_at`/`expires_at` window with type defaults + hard ceiling (§5) — **required**.
- Marker-based render + `BlockDetailView`/`ParkedCarDetailView` banner consumption (§9) — **required**.
- Trust/abuse: RLS reuse, extended auto-resolve, rate limit (§6) — **required**.
- PII-safe evidence storage (§7) — **required**, this is a real exposure risk if skipped, not a nice-to-have.
- Construction reuses the identical flow (§9.3) — **required** to actually prove the shared primitive, not
  just claim it.

### Explicitly deferred (named follow-ups, not silently dropped)
- Persistent offline submission queue (§8).
- Evidence-photo visibility to other users, with any redaction.
- Cross-street/typed-picker extent selection as an accessibility alternative to tap-select.
- Dashed/hatched polyline render treatment (vs. marker).
- Author-side extension UI for reports nearing their hard ceiling.
- Tier 1 open-data ingestion of NYC's construction-permit feed.
- Fixing/repointing the stale film-permit ingest cron.

### Sizing honesty
This touches 1 new table, 1 new Storage bucket, 2 new columns, 1 extended trigger, 1 new rate-limit
trigger, ~4 new/extended iOS views, a new map interaction mode, a new overlay type in the most
regression-sensitive file in the codebase, and a third network fetch channel. Even with the cuts above,
this is realistically **backend: 1 session; iOS: 4–6 sessions** (B1 small, B2 the largest given the map
interaction + live-UI-smoke requirement, B3/B4 medium) before it's ready for design + QA. If a shorter
timeline was implied anywhere, it isn't real — recommend explicitly sequencing this after whatever's
currently ahead of it in the queue rather than treating it as a quick add-on to the existing `ReportSheet`.

---

## 12. Acceptance Criteria

**Schema (`@qa-verifier`, before any production apply):**
- [ ] **AC-S1.** `supabase/02f-block-scoped-restrictions.sql` is idempotent (safe to re-run on an
      already-applied project, no errors).
- [ ] **AC-S2.** `pins.starts_at` and `pins.report_group_id` exist, both nullable, no default that breaks
      any existing insert path (existing Tier 1/3 inserts continue to succeed unmodified).
- [ ] **AC-S3.** Insert 4 `pins` rows (1 filming report, 2 blocks × 2 curbs) sharing one `report_group_id`,
      as an authenticated crowd user: all 4 succeed under existing `pins_insert_crowd` RLS, no schema
      change required to that policy.
- [ ] **AC-S4.** `pin_evidence` insert as the uploading user succeeds; select as a **different**
      authenticated user returns zero rows; select via `pins_with_author` never includes evidence data
      (column doesn't exist on that view).
- [ ] **AC-S5.** A crowd `filming` pin with no `meta.permit_id` key coexists with an open-data `filming`
      pin that does have one — `pins_filming_permit_id_uidx` does not reject either insert.
- [ ] **AC-S6.** Extended `auto_resolve_on_dispute`: a `source=crowd, pin_type=filming, lifespan=session`
      pin reaching 3 disputes gets `resolved_at` set (currently it would NOT — this is the specific gap
      closed in §6). An `ephemeral` crowd pin at 3 disputes still resolves (no regression to existing
      behavior).
- [ ] **AC-S7.** Rate-limit trigger: a 4th `report_group_id`-distinct block-scoped insert by the same
      `author_id` within 24 hours is rejected; the 3rd succeeds.
- [ ] **AC-S8.** Hard-ceiling constraint rejects an insert where `expires_at` exceeds `starts_at + 7 days`
      for `filming` or `starts_at + 90 days` for `construction`.

**iOS models (`B1`, unit tests, no DB dependency):**
- [ ] **AC-I1.** `Segment.blockfaceKey` is direction-agnostic: two fixture `Segment`s with `from`/`to`
      swapped but otherwise identical produce the identical key.
- [ ] **AC-I2.** `Segment.blockfaceKey` differs by `side` (E vs W of the same street/from/to produce
      different keys).
- [ ] **AC-I3.** `CommunityPin` decodes a fixture row with `starts_at` present and with `starts_at: null`
      without error; `startsAt` is optional (`Date?`).
- [ ] **AC-I4.** No `Calendar.current` usage in any new/modified file (existing project-wide invariant).

**Report flow (`B2`/`B3`, `@ios-engineer` unit tests + smoke):**
- [ ] **AC-R1.** Block-select mode: tapping a rendered segment adds its `blockfaceKey` to
      `selectedBlockKeys`; tapping it again removes it.
- [ ] **AC-R2.** "Both curbs" ON: tapping one side auto-adds the matching opposite-side segment (same
      street, same unordered from/to, different side) if one is currently loaded; if no opposite-side
      segment is loaded/found, only the tapped side is added (no crash, no silent no-op — surfaces as a
      1-block selection).
- [ ] **AC-R3.** Continue is disabled with zero blocks selected.
- [ ] **AC-R4.** Submitting Kevin's canonical case (2 blocks, both curbs) produces exactly 4 `pins` rows,
      all sharing one `report_group_id`, each with the correct `segment_id` blockface key for its
      block/side.
- [ ] **AC-R5.** Photo capture is required to submit (Continue/Submit disabled without a captured image).
- [ ] **AC-R6.** "Restriction ends" left blank → `expires_at` computed as `starts_at + <type default>`
      (24h filming / 14d construction), and the UI explicitly states the assumed default before submit.
- [ ] **AC-R7.** No structured field exists in the form for a name or phone number (manual code-review
      check, not just a test — confirms §7's design decision wasn't silently reversed).
- [ ] **AC-R8.** A failed submit (network error) preserves the entered form state and captured photo in
      the still-open sheet, with a retry affordance (mirrors `ReportSheet.submitError`).
- [ ] **AC-R9.** Live-UI-smoke screenshot of block-select mode with 2+ blocks highlighted, captured before
      merge (per §9.1's mandatory gate for any `MapViewRepresentable` overlay touch).

**Consumption (`B4`):**
- [ ] **AC-C1.** `CommunityPinService`'s 3rd fetch channel (`buildCrowdBlockScopedRequest`) returns
      `source=crowd, pin_type in (filming, construction)` rows and merges them into `visiblePins`
      alongside the existing two channels — verified this is genuinely new coverage, not already handled
      by channel 1 or 2 (see the concrete gap named in §3.4).
- [ ] **AC-C2.** A block-scoped pin whose window has not yet started (`starts_at` in the future) is still
      fetched (not filtered out by the existing client-side expiry filter, which only checks
      `expires_at`) — confirms `clientSideFilter` doesn't need to change, but the UI must visually
      distinguish "upcoming" from "active" (a one-line badge difference, not a new filter).
- [ ] **AC-C3.** `BlockDetailView` / `ParkedCarDetailView` show the "Temporary restriction" banner when
      the viewed `Segment.blockfaceKey` matches an active (or upcoming) grouped-report pin's `segment_id`;
      no banner when it doesn't match.
- [ ] **AC-C4.** `PinDetailSheet`'s reactions row (`Still there?`/`Gone`) appears for `lifespan in
      (session, durable)` block-scoped pins, not just `ephemeral` (the one-line gate widen at
      `PinDetailSheet.swift:55`).
- [ ] **AC-C5.** Tapping a marker for one blockface in a 4-blockface report shows, at minimum, that this
      specific block is covered and the shared window — full multi-block summary display is nice-to-have,
      not required for AC pass.

**TF2-15 shared-primitive proof:**
- [ ] **AC-T1.** Submitting a `construction`-typed report through the identical
      `BlockRestrictionReportSheet` (type picker set to Construction) produces correctly-typed `pins` rows
      with `pin_type='construction'`, construction's own default/ceiling window, and renders with the
      construction glyph/color — with **zero** additional files touched beyond the type-specific
      branches already covered by B2/B4's work.

---

## 13. Open Questions (Kevin)

**OQ-1 🔴 (semi-blocking — affects §9.1 scope).** Is a marker-only render treatment an acceptable reading of
"overlay, not recolor" for phase 1, or do you want the dashed/hatched polyline treatment in the initial
cut? Recommendation: marker-only for phase 1 — it's the proven, zero-new-overlay-type path; the polyline
treatment is a real visual improvement but adds meaningfully more `MapViewRepresentable` surface for a
first ship. Not fully blocking since engineering can start on everything else regardless, but B2's overlay
scope depends on the answer.

**OQ-2 (non-blocking).** Type-specific default windows (24h filming / 14d construction) and hard ceilings
(7d / 90d) — these are my first-pass numbers, not measured against real permit durations. Fine to ship and
tune after the first few real reports; flagging so they're understood as placeholders, not researched
values.

**OQ-3 (non-blocking).** Rate limit of 3 block-scoped reports per author per 24h — arbitrary, matching the
existing dispute-threshold's "pick a reasonable small number" precedent (`docs/tier3-auth-and-reactions-spec.md`
OQ-2). Fine to start here and adjust.

**OQ-4 (non-blocking).** Entry point placement — I recommended extending the existing long-press
confirmationDialog with a third action (§4.2 step 1) rather than a new toolbar button, to avoid further
crowding the toolbar cluster (`?` button just shipped there via FT-13). If you'd rather it live elsewhere
(e.g., inside the existing report flow as a type choice within `ReportSheet` itself rather than a fully
separate sheet), say so before B2 starts — it's a meaningfully different information architecture, not a
find-and-replace.

**OQ-5 (non-blocking).** Should "Evidence photo attached ✓" (a boolean, not the photo itself) be visible to
other users in phase 1 as a trust signal? I left it out of phase 1 (§7) to keep the cut minimal, but it's
cheap to add (one boolean, no PII exposure) if you want it now rather than as a follow-up.

---

## 14. Out-of-Scope Follow-Ups

**Persistent offline submission queue** (§8, §15). Real user value (curbside cellular is genuinely
unreliable) but sized as its own unit of work — `PendingBlockReportQueue` with local photo persistence +
independent retry for the pins-insert and evidence-upload steps. Owner: `@ios-engineer`, post-phase-1.

**Evidence-photo visibility + redaction.** Showing the photo to other users needs either manual moderation
tooling or automated redaction (blur detected phone numbers/names) — neither exists. The phase-2 vision/OCR
work Kevin already scoped is the natural place this gets solved for free (if you can OCR the sign to
pre-fill the form, you can also OCR-and-blur PII before ever showing the raw image). Don't build a
one-off redaction pass before that lands.

**Tier 1 construction-permit open-data ingestion.** TF2-15's own roadmap note names this ("ingest NYC
street-construction permits as Tier 1 `construction` pins... + crowd reports for what permits miss"). This
spec only builds the crowd half. The open-data half is a new Edge Function + cron mirroring
`ingest-film-permits`, and needs its own dataset investigation (which NYC feed, how fresh, does it even
cover active/in-progress permits vs. just approved-but-not-started). Owner: `@backend-data`, separate spec
recommended given it's its own ingestion pipeline, not a one-line addition.

**Investigate the stale film-permit dataset.** Confirmed today: `tg4x-b46p` has zero rows matching E 2nd
St and a newest `startdatetime` of 2026-05-12 across all 18,501 rows — roughly 3 months stale as of
2026-08-11. Decide whether NYC retired/moved the dataset, whether a different feed replaced it, and whether
`ingest-film-permits`'s daily cron (`supabase/02d-ingest-cron.sql`) should be fixed, repointed, or disabled
(a silently no-op'ing daily cron job is wasted infrastructure either way). **Explicitly not a blocker for
this spec** — the crowd path this spec builds is designed to work whether or not that pipeline is ever
fixed. Owner: `@backend-data`, small standalone investigation.

**Author-side extension for long-running construction reports.** A construction closure that's still
accurate at day 85 of its 90-day ceiling currently just needs a fresh report from anyone. A dedicated
"still ongoing, extend" affordance (patching `expires_at` under the existing author-only `pins_update_own`
RLS — no schema change needed) is a small, self-contained follow-up once real construction reports show
this is actually a friction point in practice, not before.

**Cross-street/typed-picker extent selection.** Tap-select (§4) covers Kevin's use case and every case
where the reporter is at the location. If a future need for remote/non-present reporting emerges, a
typed/picker fallback would need to solve the FT-14-class naming problem for real — worth its own design
pass at that point, not worth building speculatively now.

---

## 15. Things I'm flagging as risks, not rubber-stamping

**This is genuinely a multi-session feature disguised by a single field-testing log entry.** The FT-15 log
entry reads as one bullet point ("ingest this and update information for specific blocks"); the actual
shape (§11) is a new table, a new Storage bucket, two extended triggers, a new map interaction, a new
overlay type in the single most regression-sensitive file in the codebase, and a third network channel.
I've cut the offline queue and photo-visibility surfaces specifically because bundling them in would push
this well past what a single spec/PR/QA cycle should try to carry — recommend resisting the urge to
re-add them "since we're already in there."

**The `MapViewRepresentable.swift` touch is the one piece I'd want extra eyes on before it starts**, given
this exact file's history (the W8.5c-polish merge-then-same-day-revert, `docs/qa/w8.5c-polish-pass-1-2026-05-25.md`
and the HANDOFF.md W8.5c-polish row). The additive-overlay + `CoordinatorActions`-closure + live-UI-smoke
pattern that resolved that saga is well-established now and this spec deliberately follows it — but it's
worth Kevin knowing this feature isn't "just a new report type," it's touching the same load-bearing file
that's burned the team before.

**I did not spec a way to *remove* a wrongly-created report short of 3 disputes or hard expiry**, beyond
the existing author-only delete (`pins_delete_own`, which already exists and needs no new work — an author
who fat-fingers a report can just delete it). Flagging only because it wasn't explicitly asked about and
I want it visible that the answer is "already covered by existing RLS," not "unaddressed."
