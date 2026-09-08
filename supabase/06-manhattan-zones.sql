-- WePark Community 2.0 — S14 Manhattan zone map
--
-- ⚠️ DRAFT — DO NOT APPLY UNTIL THE PROPOSAL IS RULED. ⚠️
-- This migration is a companion artifact to docs/community-2.0-manhattan-zones.md (the proposal doc
-- Kevin reviews first — zone list, sizing, boundary rationale, the three hardest axis-aligned
-- compromises, and the preview HTML at docs/community-2.0-manhattan-zones-preview.html). Do not run
-- this in the Supabase SQL editor before that doc has been ruled on. Per repo convention, Kevin
-- applies all Supabase migrations to production by hand — this file is written and stopped, per
-- HANDOFF.md's standing instruction.
--
-- Spec: docs/community-2.0-manhattan-zones.md. Roadmap: docs/community-2.0-roadmap.md S14.
-- Open item: docs/open-items.md #15③ ("a lot more zones across Manhattan, reasonable sizes,
-- obvious/clear boundaries" — Kevin, 2026-09-06).
--
-- Depends on: 01-mvp-schema.sql (public.zones), 03-community-2.0-schema.sql §2.3 (the existing
-- nolita/soho/les seed + the soho-les legacy archive). Idempotent — every statement below is safe
-- to re-run (upsert on the zones primary key).
--
-- ============================================================================================
-- ID-STABILITY DECISION (see proposal doc's "how Kevin reviews this" / id-stability section for
-- full reasoning) — restated here because it governs every statement below:
--   - 'nolita'    — UNTOUCHED. Box unchanged. Not flagged as oversized; minimal-disruption default.
--   - 'soho'      — id kept, box REWORKED (widened south to Canal St — the original box stopped
--                   ~half a mile north of Canal, silently excluding the southern half of real SoHo).
--   - 'les'       — id kept, box REWORKED/SHRUNK (Kevin's explicit complaint, S13a gate,
--                   docs/open-items.md #15①: the seeded LES box was oversized relative to nolita/soho
--                   — it dipped south into Two Bridges/Chinatown territory and its listed "north edge"
--                   didn't even reach Houston St). New box: Houston St to Grand/Delancey St, the
--                   Bowery to the East River — the authentic LES footprint, still wider than the
--                   ~15-30 block target (see proposal doc's "accepted exceptions" list) but no longer
--                   overlapping two other neighborhoods' worth of blocks.
--   - 'soho-les'  — UNTOUCHED (legacy, retired 2026-08-26). Never rewritten or deleted here.
--                   zone_messages.zone_id is `references public.zones(id) on delete cascade`
--                   (01-mvp-schema.sql:74) — deleting this row would cascade-delete every historical
--                   SoHo/LES chat message. Same reasoning 03-community-2.0-schema.sql already
--                   documented for this row; repeated here so nobody "cleans it up" in a future pass.
--   - All 38 other rows below are BRAND NEW ids — no existing pin/message/push-token references them,
--     so there is no migration-compatibility concern for them.
--
-- Reworking soho/les box columns is non-breaking for existing data: `pins.zone_id`,
-- `zone_messages.zone_id`, and `device_push_tokens.zone_id` all store the *id string*, not a
-- denormalized copy of the box — an existing row tagged zone_id='les' stays validly associated with
-- 'les' after this migration, no matter how its box moves. The only behavior that changes is
-- FORWARD: (a) any client-side reverse geocode (`CommunityZoneBounds.zoneId(forLat:lng:)`-style
-- lookup) run against the new box for a *new* write, and (b) the zone-boundary overlay (S13a) drawing
-- a visibly different rectangle than before for a pin whose zone_id predates this migration. Neither
-- is a data-integrity concern. Flagged for @ios-engineer/@pwa-maintainer in the PR description.
-- ============================================================================================

-- ------------------------------------------------------------------------------------------------
-- Rework soho and les (id-stable, box change only).
-- ------------------------------------------------------------------------------------------------
insert into public.zones (id, name, description, lat_min, lat_max, lng_min, lng_max) values
  ('soho', 'SoHo', 'SoHo', 40.7185, 40.7237, -74.0050, -73.9970),
  ('les',  'Lower East Side', 'Lower East Side', 40.7185, 40.7237, -73.9930, -73.9770)
on conflict (id) do update set
  name = excluded.name,
  description = excluded.description,
  lat_min = excluded.lat_min,
  lat_max = excluded.lat_max,
  lng_min = excluded.lng_min,
  lng_max = excluded.lng_max;

-- 'nolita' is intentionally absent from this file — box unchanged, see the id-stability note above.
-- 'soho-les' is intentionally absent from this file — legacy archive, never rewritten here.

-- ------------------------------------------------------------------------------------------------
-- 38 new zones, Battery Park to Inwood. Boundaries and rationale: docs/community-2.0-manhattan-zones.md
-- (full boundary-description table + the "hardest compromises" section — several of these boxes
-- deliberately overlap by a block or two at a seam; that document explains which, and why, and what
-- tie-break rule the client-side reverse lookup should use when a point matches more than one box).
--
-- ⚠️ COORDINATE CONFIDENCE NOTE: latitudes/longitudes below 96th St are anchored fairly tightly to
-- well-known landmark intersections. North of 96th (and especially north of 125th) coordinate density
-- in this pass was lower and several values are extrapolated from block-spacing math rather than a
-- named landmark — spot-check the Harlem/Washington Heights/Inwood rows against Google Maps or OSM
-- before applying. See the proposal doc for the full caveat.
-- ------------------------------------------------------------------------------------------------
insert into public.zones (id, name, description, lat_min, lat_max, lng_min, lng_max) values
  ('battery-park-city', 'Battery Park City', 'Battery Park City & the World Trade Center', 40.7040, 40.7175, -74.0195, -74.0135),
  ('financial-district', 'Financial District', 'Wall Street & Bowling Green', 40.7015, 40.7115, -74.0135, -74.0035),
  ('seaport-civic-center', 'Seaport / Civic Center', 'South Street Seaport, City Hall, Foley Square', 40.7110, 40.7155, -74.0075, -73.9995),
  ('tribeca', 'TriBeCa', 'TriBeCa', 40.7150, 40.7205, -74.0145, -74.0035),
  ('two-bridges', 'Two Bridges', 'Two Bridges, between the Brooklyn and Manhattan Bridges', 40.7095, 40.7145, -73.9970, -73.9885),
  ('chinatown', 'Chinatown', 'Chinatown, incl. the Little Italy / Mulberry St strip', 40.7145, 40.7185, -74.0010, -73.9930),
  ('noho', 'NoHo', 'NoHo', 40.7237, 40.7359, -73.9975, -73.9930),
  ('greenwich-village', 'Greenwich Village', 'Washington Square Park & NYU', 40.7237, 40.7359, -74.0050, -73.9975),
  ('west-village', 'West Village', 'West Village', 40.7275, 40.7395, -74.0090, -74.0050),
  ('east-village', 'East Village', 'East Village', 40.7237, 40.7359, -73.9930, -73.9808),
  ('alphabet-city', 'Alphabet City', 'Alphabet City', 40.7237, 40.7359, -73.9808, -73.9700),
  ('chelsea', 'Chelsea', 'Chelsea & the High Line', 40.7359, 40.7420, -74.0090, -73.9945),
  ('union-square-flatiron', 'Union Square / Flatiron', 'Union Square & the Flatiron District', 40.7359, 40.7420, -73.9945, -73.9870),
  ('gramercy', 'Gramercy', 'Gramercy Park', 40.7359, 40.7420, -73.9870, -73.9800),
  ('stuyvesant-town', 'Stuyvesant Town', 'Stuy Town & Peter Cooper Village', 40.7359, 40.7420, -73.9800, -73.9740),
  ('hudson-yards', 'Hudson Yards', 'Hudson Yards', 40.7420, 40.7484, -74.0090, -73.9945),
  ('garment-district', 'Garment District', 'Garment District / NoMad border, Madison Square Park', 40.7420, 40.7484, -73.9945, -73.9860),
  ('murray-hill', 'Murray Hill / Kips Bay', 'Murray Hill & Kips Bay', 40.7420, 40.7562, -73.9860, -73.9740),
  ('hells-kitchen', 'Hell''s Kitchen', 'Hell''s Kitchen / Clinton', 40.7484, 40.7685, -74.0090, -73.9910),
  ('midtown-core', 'Midtown (Herald Square)', 'Herald Square, Koreatown''s north edge, Penn Station', 40.7484, 40.7562, -73.9910, -73.9860),
  ('times-square-theater-district', 'Times Square / Theater District', 'Times Square, Theater District, Rockefeller Center', 40.7562, 40.7685, -73.9910, -73.9787),
  ('midtown-east', 'Midtown East', 'Midtown East', 40.7562, 40.7685, -73.9787, -73.9700),
  ('turtle-bay-sutton', 'Turtle Bay / Sutton Place', 'The UN & Sutton Place', 40.7562, 40.7685, -73.9700, -73.9600),
  ('lincoln-square', 'Lincoln Square', 'Lincoln Center & Lincoln Towers', 40.7685, 40.7790, -73.9990, -73.9820),
  ('upper-west-side', 'Upper West Side', 'Upper West Side', 40.7790, 40.7936, -73.9990, -73.9730),
  ('manhattan-valley', 'Manhattan Valley', 'Manhattan Valley', 40.7936, 40.8028, -73.9880, -73.9650),
  ('central-park', 'Central Park', 'The park itself — low-confidence/optional, see notes', 40.7685, 40.8028, -73.9819, -73.9493),
  ('lenox-hill', 'Lenox Hill', 'Lenox Hill', 40.7685, 40.7813, -73.9700, -73.9500),
  ('yorkville-carnegie-hill', 'Yorkville / Carnegie Hill', 'Yorkville & Carnegie Hill', 40.7813, 40.7936, -73.9650, -73.9420),
  ('morningside-heights', 'Morningside Heights', 'Columbia University', 40.8028, 40.8115, -73.9720, -73.9560),
  ('central-harlem', 'Central Harlem', 'Harlem''s 125th St corridor, Apollo Theater', 40.8028, 40.8268, -73.9530, -73.9420),
  ('east-harlem', 'East Harlem', 'El Barrio / Spanish Harlem', 40.7936, 40.8268, -73.9420, -73.9280),
  ('manhattanville', 'Manhattanville', 'Manhattanville', 40.8115, 40.8180, -73.9670, -73.9530),
  ('hamilton-heights', 'Hamilton Heights', 'Hamilton Heights, City College', 40.8180, 40.8339, -73.9670, -73.9530),
  ('sugar-hill', 'Sugar Hill', 'Sugar Hill', 40.8268, 40.8339, -73.9530, -73.9280),
  ('washington-heights', 'Washington Heights', 'Washington Heights', 40.8339, 40.8514, -73.9600, -73.9280),
  ('hudson-heights', 'Hudson Heights / Fort George', 'Fort Tryon Park, The Cloisters, Fort George', 40.8514, 40.8585, -73.9450, -73.9280),
  ('inwood', 'Inwood', 'Inwood', 40.8585, 40.8785, -73.9370, -73.9130)
on conflict (id) do update set
  name = excluded.name,
  description = excluded.description,
  lat_min = excluded.lat_min,
  lat_max = excluded.lat_max,
  lng_min = excluded.lng_min,
  lng_max = excluded.lng_max;

-- ------------------------------------------------------------------------------------------------
-- RLS / grants: NO CHANGE NEEDED.
-- ------------------------------------------------------------------------------------------------
-- public.zones already carries `zones_select_all` ("for select using (true)", 01-mvp-schema.sql:48-50)
-- and the table has been publicly readable by anon+authenticated since Phase 0 — the existing 3-zone
-- picker already depends on it. Adding 38 more rows to an already-public table needs no new policy.
-- Verify with a quick anon-key curl probe after applying (same probe pattern as every other schema
-- change per HANDOFF.md's workflow):
--   curl "$SUPABASE_URL/rest/v1/zones?select=id,name&order=id" -H "apikey: $ANON_KEY"
-- Expect 42 rows back after this migration: soho-les (legacy) + nolita + soho + les + 38 new. The
-- client is responsible for filtering the retired 'soho-les' id out of any picker UI, same as it
-- presumably already does today.
--
-- Realtime: NO CHANGE NEEDED. public.zones was never added to the supabase_realtime publication
-- (only zone_messages was, 01-mvp-schema.sql:104-114) and doesn't need to be — zones is fetched
-- once at launch per the proposal doc's client fetch contract, not subscribed to live.
