# Community 2.0 — S14 Manhattan Zone Map Proposal

**Status: DESIGN + DRAFT, NOT-FOR-MERGE-UNTIL-KEVIN-RULES.** This document and its companion migration
(`supabase/06-manhattan-zones.sql`, header marked DRAFT) are a proposal for Kevin's review, not a
shipped change. Nothing here is applied. Per repo convention, Kevin applies Supabase migrations to
production by hand once he's ruled on this.

**Directive this answers** (Kevin, 2026-09-06, verbatim): *"we need a lot more zones across manhattan
and reasonable sizes for each as well as obvious/clear boundaries."*

**Context:** `docs/community-2.0-roadmap.md` row S14, `docs/open-items.md` item 15③. Today
`public.zones` has 3 active rows (`nolita`/`soho`/`les`, seeded by `03-community-2.0-schema.sql` §2.3)
plus a retired legacy archive (`soho-les`). The app hardcodes the same three boxes client-side
(`ios/WePark/WePark/Services/CommunityZoneBounds.swift`). This proposal is the **data design and the
client fetch contract** — replacing the hardcoded Swift table with fetch-at-launch is a later,
separate client session (explicitly out of scope here; no iOS file is touched by this PR).

---

## Headline

- **41 zones total**: 3 existing ids (`nolita` unchanged, `soho` and `les` resized) + 38 new ids,
  covering Battery Park to Inwood — the full island, not just "below 110th," because extending north
  was cheap given the same grid-snapping method and leaves no part of Manhattan without a zone.
- **Zero ids change or get deleted.** `nolita`/`soho`/`les` keep their ids; only `soho`'s and `les`'s
  boxes move. The retired `soho-les` archive is untouched. See "ID-stability decision" below for why
  this matters and what it costs.
- Slightly above the ~25-40 zone estimate in the roadmap row, because of the full-island extension —
  the Manhattan-below-110th subset alone is 33 zones, in range.

---

## The zone list

Every boundary below is snapped to a named street, avenue, or landmark — never mid-block, per Kevin's
"obvious/clear boundaries" directive. `status`: `kept` = id and box unchanged; `reworked` = id kept,
box changed; `new` = brand-new id.

| id | name | lat_min | lat_max | lng_min | lng_max | boundary description | status |
|---|---|---|---|---|---|---|---|
| `battery-park-city` | Battery Park City | 40.7040 | 40.7175 | -74.0195 | -74.0135 | Battery Pl to Chambers St, the Hudson River to West St | new |
| `financial-district` | Financial District | 40.7015 | 40.7115 | -74.0135 | -74.0035 | The Battery to Fulton St, West St to the FDR Drive | new |
| `seaport-civic-center` | Seaport / Civic Center | 40.7110 | 40.7155 | -74.0075 | -73.9995 | Fulton St to Chambers St, Broadway to the FDR Drive | new |
| `tribeca` | TriBeCa | 40.7150 | 40.7205 | -74.0145 | -74.0035 | Chambers St to Canal St, the Hudson River to Broadway | new |
| `two-bridges` | Two Bridges | 40.7095 | 40.7145 | -73.9970 | -73.9885 | Division/Canal St to the East River, the Brooklyn Bridge to the Manhattan Bridge | new |
| `chinatown` | Chinatown | 40.7145 | 40.7185 | -74.0010 | -73.9930 | Worth St to Canal St, Centre St to the Bowery (incl. Little Italy's Mulberry St strip) | new |
| `soho` | SoHo | 40.7185 | 40.7237 | -74.0050 | -73.9970 | Canal St to Houston St, 6th Ave/Sullivan St to Lafayette/Centre St | **reworked** |
| `nolita` | NoLita | 40.7217 | 40.7256 | -73.9967 | -73.9930 | Spring/Kenmare St to Houston St, Lafayette/Centre St to the Bowery | **kept, unchanged** |
| `les` | Lower East Side | 40.7185 | 40.7237 | -73.9930 | -73.9770 | Grand/Delancey St to Houston St, the Bowery to the East River | **reworked/shrunk** |
| `noho` | NoHo | 40.7237 | 40.7359 | -73.9975 | -73.9930 | Houston St to 14th St, Broadway to the Bowery/3rd Ave | new |
| `greenwich-village` | Greenwich Village | 40.7237 | 40.7359 | -74.0050 | -73.9975 | Houston St to 14th St, 6th Ave to Broadway (Washington Sq Park, NYU) | new |
| `west-village` | West Village | 40.7275 | 40.7395 | -74.0090 | -74.0050 | Houston St to 14th St, the Hudson River to 6th/7th Ave | new |
| `east-village` | East Village | 40.7237 | 40.7359 | -73.9930 | -73.9808 | Houston St to 14th St, the Bowery/3rd Ave to Avenue A | new |
| `alphabet-city` | Alphabet City | 40.7237 | 40.7359 | -73.9808 | -73.9700 | Houston St to 14th St, Avenue A to the East River | new |
| `chelsea` | Chelsea | 40.7359 | 40.7420 | -74.0090 | -73.9945 | 14th St to 23rd St, the Hudson River to 6th Ave | new |
| `union-square-flatiron` | Union Square / Flatiron | 40.7359 | 40.7420 | -73.9945 | -73.9870 | 14th St to 23rd St, 6th Ave to Park Ave South | new |
| `gramercy` | Gramercy | 40.7359 | 40.7420 | -73.9870 | -73.9800 | 14th St to 23rd St, Park Ave South to 1st Ave | new |
| `stuyvesant-town` | Stuyvesant Town | 40.7359 | 40.7420 | -73.9800 | -73.9740 | 14th St to 23rd St, 1st Ave to the East River (Stuy Town & PCV) | new |
| `hudson-yards` | Hudson Yards | 40.7420 | 40.7484 | -74.0090 | -73.9945 | 23rd St to 34th St, the Hudson River to 8th Ave | new |
| `garment-district` | Garment District | 40.7420 | 40.7484 | -73.9945 | -73.9860 | 23rd St to 34th St, 8th Ave to 5th Ave (Madison Square Park, NoMad border) | new |
| `murray-hill` | Murray Hill / Kips Bay | 40.7420 | 40.7562 | -73.9860 | -73.9740 | 23rd St to 42nd St, 5th Ave to the East River | new |
| `hells-kitchen` | Hell's Kitchen | 40.7484 | 40.7685 | -74.0090 | -73.9910 | 34th St to 59th St, the Hudson River to 8th Ave | new |
| `midtown-core` | Midtown (Herald Square) | 40.7484 | 40.7562 | -73.9910 | -73.9860 | 34th St to 42nd St, 8th Ave to 5th Ave (Herald Sq, Koreatown's north edge, Penn Station) | new |
| `times-square-theater-district` | Times Square / Theater District | 40.7562 | 40.7685 | -73.9910 | -73.9787 | 42nd St to 59th St, 8th Ave to 5th Ave (incl. Rockefeller Center) | new |
| `midtown-east` | Midtown East | 40.7562 | 40.7685 | -73.9787 | -73.9700 | 42nd St to 59th St, 5th Ave to Park/Lexington Ave | new |
| `turtle-bay-sutton` | Turtle Bay / Sutton Place | 40.7562 | 40.7685 | -73.9700 | -73.9600 | 42nd St to 59th St, Park/Lexington Ave to the East River (the UN, Sutton Place) | new |
| `lincoln-square` | Lincoln Square | 40.7685 | 40.7790 | -73.9990 | -73.9820 | 59th St to 72nd St, the Hudson River to Central Park West | new |
| `upper-west-side` | Upper West Side | 40.7790 | 40.7936 | -73.9990 | -73.9730 | 72nd St to 96th St, the Hudson River to Central Park West | new |
| `manhattan-valley` | Manhattan Valley | 40.7936 | 40.8028 | -73.9880 | -73.9650 | 96th St to 110th St, Riverside Dr/Broadway to Central Park West | new |
| `central-park` | Central Park | 40.7685 | 40.8028 | -73.9819 | -73.9493 | 59th St to 110th St, Central Park West to 5th Ave — **low confidence, see notes** | new |
| `lenox-hill` | Lenox Hill | 40.7685 | 40.7813 | -73.9700 | -73.9500 | 59th St to 77th St, 5th Ave to the East River | new |
| `yorkville-carnegie-hill` | Yorkville / Carnegie Hill | 40.7813 | 40.7936 | -73.9650 | -73.9420 | 77th St to 96th St, 5th Ave to the East River | new |
| `morningside-heights` | Morningside Heights | 40.8028 | 40.8115 | -73.9720 | -73.9560 | 110th St to 125th St, the Hudson River/Riverside Dr to Morningside Ave (Columbia) | new |
| `central-harlem` | Central Harlem | 40.8028 | 40.8268 | -73.9530 | -73.9420 | 110th St to 145th St, St Nicholas/Morningside Ave to 5th Ave/Mount Morris Park | new |
| `east-harlem` | East Harlem | 40.7936 | 40.8268 | -73.9420 | -73.9280 | 96th St to 145th St, 5th Ave to the East/Harlem River (El Barrio) | new |
| `manhattanville` | Manhattanville | 40.8115 | 40.8180 | -73.9670 | -73.9530 | 125th St to 135th St, the Hudson River to St Nicholas/Amsterdam Ave | new |
| `hamilton-heights` | Hamilton Heights | 40.8180 | 40.8339 | -73.9670 | -73.9530 | 135th St to 155th St, the Hudson River/Riverside Dr to St Nicholas/Amsterdam Ave | new |
| `sugar-hill` | Sugar Hill | 40.8268 | 40.8339 | -73.9530 | -73.9280 | 145th St to 155th St, Amsterdam/St Nicholas Ave to the Harlem River | new |
| `washington-heights` | Washington Heights | 40.8339 | 40.8514 | -73.9600 | -73.9280 | 155th St to 181st St, the Hudson River to the Harlem River (full island width) | new |
| `hudson-heights` | Hudson Heights / Fort George | 40.8514 | 40.8585 | -73.9450 | -73.9280 | 181st St to 190th St, the Hudson River to the Harlem River (Fort Tryon Park, The Cloisters, Fort George — full island width) | new |
| `inwood` | Inwood | 40.8585 | 40.8785 | -73.9370 | -73.9130 | 190th St to the island's northern tip, the Hudson River to the Harlem River | new |

`soho-les` (the pre-2026-08-26 legacy id) is not in this table — it is untouched, retained only as a
chat-history archive. It should never appear in a picker UI (the client already filters it today).

### Coordinate confidence caveat

Latitudes/longitudes below 96th St are anchored fairly tightly to well-known intersections (Union
Square, Times Square, Columbus Circle, Lincoln Center, the American Museum of Natural History, etc.)
and are exactly right for `soho`/`les` since those two boxes reuse the Houston St latitude
(40.7237) already corrected and applied to production in the QA pass on PR #93. **North of 96th St —
and especially north of 125th St — several values are extrapolated from block-spacing math
(≈0.0007246°/block) rather than a named landmark**, and confidence degrades the further north you go
(the Washington Heights/Inwood latitudes could plausibly be off by 100-300m). **Before this migration
is applied, spot-check the Harlem/Washington Heights/Inwood rows against Google Maps or OpenStreetMap.**
This is a reasonable bar for a first-pass axis-aligned zone map, not a surveyed boundary set.

---

## Sizing: the ~15-30 block target, and where it was deliberately broken

Most zones land in the 15-30 block "crew scale" range the original brief asked for (e.g. `nolita`,
`chinatown`, `two-bridges`, `manhattanville`). A handful of real, strongly-claimed neighborhood
identities are genuinely bigger or more elongated than that in real life, and shrinking them to hit a
number would have meant either inventing sub-neighborhood names nobody actually uses, or leaving real
streets uncovered by any zone. I chose to let these run larger rather than do either:

- **`les` (Lower East Side)** — still the widest zone by design (Bowery to the East River is a real,
  wide neighborhood), but now roughly a third the area of the old oversized box, and no longer bleeding
  into Two Bridges/Chinatown to its south.
- **`hells-kitchen`, `chelsea`, `washington-heights`, `central-harlem`, `east-harlem`** — these are
  authentically long, narrow, north-south-elongated neighborhoods (Hell's Kitchen alone spans 34th to
  59th St). Axis-aligned rectangles handle an elongated *aspect ratio* fine — that's not a diagonal
  problem — so these are wider-than-target by design, not by axis-alignment failure. Flagged here so
  nobody "fixes" them into meaningless invented sub-zones later without a product reason.
- **`central-park`** — included for completeness (so a pin dropped on a park drive/transverse doesn't
  land in `zone_id = null`), but it's the single lowest-confidence entry: Central Park is not
  rectangular in lat/lng space (it's subtly trapezoidal — its NE and NW corners sit measurably further
  east than its SE and SW corners), so any single bounding box necessarily overlaps its neighbors.
  **Recommend Kevin decide whether this zone ships at all** — it has no obvious "crew" use case beyond
  edge-case coverage.

---

## Where axis-aligned boxes can't match reality (and the compromises made)

Manhattan's real neighborhood boundaries follow diagonal streets (Broadway), the pre-1811-grid tangle
of Lower Manhattan, the natural curve of the shoreline, and the Harlem River's bend — none of which a
rectangle can represent. A programmatic overlap check across all 41 boxes (comparing every pair) found
these seams; the three below are the ones worth Kevin's attention, roughly in order of how much they
matter:

1. **West Village's diagonal streets (worst offender).** Bank St, Bethune St, Gansevoort St, and
   Greenwich Ave cut across the neighborhood at odd angles that don't follow the 14th St grid line used
   everywhere else. Real West Village (and the Meatpacking District tucked into its northeast corner)
   extends measurably above 14th St. This proposal's `west-village` box follows the real shape (extends
   to 40.7395, ~4 short blocks north of 14th) rather than clipping it at a fake-precise line — the cost
   is a real, deliberate ~30%-of-`west-village`-area overlap with `chelsea`'s northwest corner. A point
   in that sliver matches both boxes.
2. **The Chinatown / Little Italy / NoLita / SoHo border.** This is genuinely contested in real life,
   not just in this proposal — Grand St, Kenmare St, Centre St, and Mulberry St don't form a clean
   quadrant split. Two concrete seams fell out of this: (a) `chinatown`'s box is capped at Canal St to
   avoid swallowing SoHo's/NoLita's southern blocks, meaning a few blocks of "real" Chinatown between
   Canal and Grand/Hester St are attributed to `chinatown` at the Canal line rather than following
   Chinatown's actual slightly-further-north extent — a judgment call, not a data error; (b) `nolita`'s
   *existing, unchanged* box (kept per the id-stability decision) extends about two short blocks north
   of the Houston St line used for every other Canal-to-Houston zone, which makes it overlap ~49% with
   the new `noho` box immediately north of it. That overlap is **inherited from the original Phase 0
   seed**, not introduced here — `nolita`'s box was deliberately left untouched.
3. **Broadway's diagonal through Union Square / Flatiron / Herald Square / Times Square.** Broadway
   crosses the numbered-avenue grid at roughly a 28° angle from 14th St to 42nd St+, meaning any single
   north-south seam (e.g. the `union-square-flatiron` / `gramercy` boundary at Park Ave South) either
   clips a genuine Flatiron/Broadway-corridor block onto the wrong side or duplicates it. Chose Park Ave
   South / Broadway itself as the seam in each band since that's the commonly-understood dividing line,
   accepting that the Flatiron Building's own block sits right on top of it.

**Minor, low-stakes seams** (not worth Kevin's attention individually, listed for completeness): small
1-3% overlaps at `battery-park-city`/`tribeca` (Chambers St), `financial-district`/`seaport-civic-center`
(Fulton St), and `tribeca`/`soho` (Canal St) — each under 5% of the smaller box's area, consistent with
±100-150m boundary-placement noise rather than a real compromise.

**Client-side implication (flag for @ios-engineer / @pwa-maintainer):** because these boxes are not
guaranteed disjoint everywhere (unlike today's 3-zone setup, which is), the point-in-zone reverse
lookup (`CommunityZoneBounds.zoneId(forLat:lng:)`'s eventual server-fetched successor) needs a
**deterministic tie-break rule** for a point that matches more than one box. Recommendation: **smallest
matching box wins** — a more specific, smaller zone (e.g. `nolita`) should take priority over a broader
one that happens to overlap it (e.g. `noho`), since the smaller box is more likely to represent genuine
local identity for that point.

### Future upgrade path (not designed here)

The durable fix for all of the above is true polygon geometry (NTA boundaries or hand-drawn polygons)
with a real point-in-polygon lookup, replacing the bounding-box approximation entirely — this was
already flagged as the eventual path in `docs/community-2.0-reconciliation-spec.md`'s open questions
(OQ-1) and is unchanged advice here. It's a bigger lift (`postgis`, `st_contains`, a client-side
geometry library or a server-side RPC for the lookup) that should only be taken on if boxes visibly
misclassify blocks in practice — the same threshold the original 3-zone decision used.

---

## ID-stability decision

**No zone id is renamed or deleted.** `nolita`, `soho`, and `les` keep their ids; `soho-les` (the
retired legacy archive) is untouched. This was the deciding factor in every judgment call above where
box-shape purity and id-stability pulled in different directions (see the NoLita/NoHo overlap above,
for instance) — id-stability won every time.

**Why this matters:** `pins.zone_id`, `zone_messages.zone_id`, and `device_push_tokens.zone_id` all
reference `zones(id)`. `zone_messages.zone_id` is `on delete cascade` — deleting or renaming a zone id
that has chat history would cascade-delete that history. `pins.zone_id` and `device_push_tokens.zone_id`
are `on delete set null` — less catastrophic, but still means any change to an id in active use quietly
orphans existing rows' zone attribution. Since `soho` and `les` are real, live ids with real production
data (chat messages, pins, possibly push tokens), reworking their **boxes** while keeping their **ids**
is the only change that's fully non-breaking: existing rows keep their correct `zone_id` regardless of
where the box moves; only forward writes and the zone-boundary overlay's rendered rectangle change.

**If a future pass ever needs to rename or split an id** (e.g. if Kevin later decides `les` really
should split into two neighborhoods), the correct sequence is: (1) create the new id(s) with correct
boxes, (2) backfill existing rows' `zone_id` via an `UPDATE` keyed on the row's own lat/lng (not a bulk
rename), (3) only then consider archiving the old id the same way `soho-les` was archived — update its
`description` to say "superseded," never delete it while any `zone_messages` row still references it.

---

## Client fetch contract

### RLS — already open, verified by inspection

`public.zones` already carries `zones_select_all` (`for select using (true)`, `01-mvp-schema.sql:48-50`)
and has been publicly readable by `anon`/`authenticated` since Phase 0 — the existing 3-zone picker
already depends on this. **No RLS or grant change is needed for this migration.** Post-apply, verify
with the same anon-key curl probe pattern used for every other schema change:

```
curl "$SUPABASE_URL/rest/v1/zones?select=id,name&order=id" -H "apikey: $ANON_KEY"
```

Expect 42 rows back (`soho-les` + `nolita` + `soho` + `les` + 38 new). The client already needs to
filter `soho-les` out of any picker UI (it presumably does today, since it isn't one of the 3 currently
shown); that filter needs to keep working at 42 rows, not just 4.

### Fetch-at-launch, not realtime

Zones are **fetched once at cold launch**, cached in memory for the process lifetime, with a full
replace-on-next-launch (no incremental diffing needed — this is a small, rarely-changing config-like
dataset, not a live feed). `public.zones` was never added to the `supabase_realtime` publication and
shouldn't be — there's no product need for a zone map to update while the app is open.

**Recommended cache semantics:**
- On successful fetch: replace the in-memory/on-disk zone list wholesale, keyed by nothing more than
  "last successful fetch."
- On fetch failure (offline cold launch): fall back to the last-known-good persisted list rather than
  the bundled `CommunityZoneBounds` constants (once those are retired) — never block app launch on this
  fetch, matching the existing mock-fallback philosophy for Supabase connectivity generally.
- No TTL/expiry logic needed beyond "refetch on next cold launch." This isn't a security-sensitive or
  fast-changing dataset.

### What happens to a device's stored zone_id when zones change

Because ids are stable (see above), a device's already-associated `zone_id` (on a saved pin, a parked
car, or a push token) **never silently becomes invalid** just because this migration runs — the id it
already has still exists as a row. Two related situations to design for going forward, though:

1. **A pin/token's stored `zone_id` isn't in the freshly fetched zone list at all** (e.g. a future id
   really is retired). The client should never hard-fail or drop the pin — treat an unrecognized
   `zone_id` exactly like the existing `zone_id = nil` fallback path: recompute the zone from the pin's
   own stored lat/lng against the current fetched list (this is exactly what
   `CommunityZoneBounds.zoneId(forLat:lng:)`'s reverse lookup already does for nil `zone_id`s today —
   the same function should become the fallback for *unrecognized* ids too, not just nil ones).
2. **A box moves under an unchanged id** (this migration's actual `soho`/`les` case). The row's
   `zone_id` stays correct by definition (nothing about the *id* changed), but a client rendering "your
   zone box" (the S13a zone-boundary overlay) will draw a visibly different rectangle than the one the
   pin was originally placed relative to. This is a cosmetic/display consideration, not a data
   integrity one — no client action is required, but it's worth `@ios-engineer`/`@pwa-maintainer`
   knowing why an old `les`-tagged pin might render outside the newly-drawn `les` box after this ships.

### Zone-picker scaling — flagged for @designer

Today's zone picker is 3 chips. **41 zones cannot be chips.** This proposal doesn't design the UI (that's
`@designer`'s call), but the requirement is now concrete enough to hand off:

- **Recommendation: nearest-first auto-select.** Auto-select the zone containing the user's parked-car
  position (if one exists) or current location — this covers the overwhelmingly common case with zero
  taps, same spirit as the app's existing "just open it and see the map" zero-friction posture.
- A manual override is still needed for the "I want to see a different neighborhood's board" case —
  needs a scalable list/search UI (e.g. grouped by area: Downtown / Village / Midtown / Upper West /
  Upper East / Harlem / Uptown), not a flat 41-item picker.
- Flagging, not designing: this is a genuine UX question (search vs. grouped list vs. map-tap) that
  should go to `@designer` before the client-side S14 session starts.

---

## How Kevin reviews this

1. Read the zone list table above and the three hardest-compromise write-ups.
2. **Open `docs/community-2.0-manhattan-zones-preview.html` directly in a browser** (self-contained,
   no server, no external dependencies, no map tiles — it draws every box to scale on a plain lat/lng
   canvas with street-grid reference lines and labels, colored by rework status). Use it to eyeball
   sizes and coverage: does `les` finally look proportionate to `nolita`/`soho`? Do West Village and
   Chelsea's overlap look acceptable? Does Central Park's box look like it's doing more harm than good?
3. Rule on:
   - Keep the id-stability decision (nolita/soho/les ids unchanged), or force a different call.
   - Ship `central-park` or drop it.
   - Any zone that looks visibly wrong-sized or wrong-shaped in the preview.
   - The @designer hand-off for the zone-picker UI (separate follow-up, not blocking this doc).
4. Once ruled, `supabase/06-manhattan-zones.sql` is ready to run as-is in the Supabase SQL editor
   (Kevin applies, per standing convention) — no code changes needed to the SQL itself unless the
   ruling changes specific boxes.
5. **Follow-ups filed for later sessions, not this one:**
   - `@ios-engineer` / `@pwa-maintainer`: replace `CommunityZoneBounds`'s hardcoded Swift table (and
     any PWA-side equivalent) with fetch-at-launch against the now-41-row `zones` table, per the fetch
     contract above. Implement the "unrecognized zone_id falls back to reverse lookup" behavior.
     Implement the smallest-matching-box tie-break rule for the handful of documented overlapping seams.
   - `@designer`: the scalable zone-picker UI (nearest-first auto-select + a grouped/search fallback).
   - Whoever owns the S13a zone-boundary overlay: verify it still renders sanely for 41 boxes instead
     of 3 (font size, z-order for overlapping boxes, etc.) — not designed here, just flagged.
