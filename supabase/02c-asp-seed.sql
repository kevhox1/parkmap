-- WePark ASP suspension calendar seed — 2026
-- Spec: docs/tier1-open-data-ingest-spec.md §4
-- Depends on: 02-pins-schema.sql + 02b-pins-ingest-indexes.sql applied.
--
-- IDEMPOTENT: safe to paste into the Supabase SQL Editor and re-run.
-- ON CONFLICT on the partial unique index pins_asp_suspension_date_uidx
-- ((meta->>'suspension_date') WHERE pin_type='asp_suspended_today') will
-- UPDATE the existing row rather than error, so re-runs are always safe.
--
-- Coordinates: city centroid (lat 40.7128, lng -74.0060 — City Hall, Manhattan).
-- ASP suspensions are citywide; the pin row satisfies the NOT NULL constraint.
-- The iOS display layer renders these as a citywide banner, not a map point (§4.3).
--
-- expires_at: end of the suspension day in Eastern Time (23:59:59 America/New_York).
-- AT TIME ZONE 'America/New_York' produces the correct UTC offset regardless of
-- whether DST is in effect on that date — Postgres handles the transition.
--
-- author_id: null (seeded by service-role key, not a user — §4 "Both are anonymous").
-- source: 'open_data'   lifespan: 'session'   pin_type: 'asp_suspended_today'

insert into public.pins (
  pin_type,
  source,
  lifespan,
  lat,
  lng,
  segment_id,
  zone_id,
  author_id,
  expires_at,
  resolved_at,
  confirm_count,
  dispute_count,
  meta,
  notes
)
values
  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-01-01 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-01-01","reason":"New Year''s Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-01-06 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-01-06","reason":"Three Kings'' Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-01-19 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-01-19","reason":"Martin Luther King Jr.''s Birthday"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-02-12 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-02-12","reason":"Lincoln''s Birthday"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-02-16 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-02-16","reason":"Washington''s Birthday / Lunar New Year''s Eve"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-02-17 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-02-17","reason":"Lunar New Year"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-02-18 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-02-18","reason":"Ash Wednesday / Losar"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-03-03 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-03-03","reason":"Purim"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-03-20 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-03-20","reason":"Idul-Fitr (Eid Al-Fitr)"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-03-21 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-03-21","reason":"Idul-Fitr (Eid Al-Fitr)"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-04-02 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-04-02","reason":"Holy Thursday / Passover"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-04-03 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-04-03","reason":"Good Friday / Passover"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-04-08 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-04-08","reason":"Passover (7th day)"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-04-09 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-04-09","reason":"Passover (8th day) / Holy Thursday (Orthodox)"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-04-10 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-04-10","reason":"Good Friday (Orthodox)"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-05-14 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-05-14","reason":"Solemnity of the Ascension"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-05-22 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-05-22","reason":"Shavuoth"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-05-23 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-05-23","reason":"Shavuoth"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-05-25 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-05-25","reason":"Memorial Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-05-27 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-05-27","reason":"Idul-Adha (Eid Al-Adha)"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-05-28 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-05-28","reason":"Idul-Adha (Eid Al-Adha)"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-06-19 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-06-19","reason":"Juneteenth"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-07-03 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-07-03","reason":"Independence Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-07-04 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-07-04","reason":"Independence Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-07-23 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-07-23","reason":"Tisha B''Av"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-08-15 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-08-15","reason":"Feast of the Assumption"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-09-07 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-09-07","reason":"Labor Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-09-12 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-09-12","reason":"Rosh Hashanah"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-09-13 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-09-13","reason":"Rosh Hashanah"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-09-21 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-09-21","reason":"Yom Kippur"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-09-26 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-09-26","reason":"Succoth"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-09-27 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-09-27","reason":"Succoth"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-10-03 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-10-03","reason":"Shemini Atzereth"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-10-04 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-10-04","reason":"Simchas Torah"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-10-12 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-10-12","reason":"Columbus Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-11-01 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-11-01","reason":"All Saints'' Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-11-03 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-11-03","reason":"Election Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-11-08 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-11-08","reason":"Diwali"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-11-11 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-11-11","reason":"Veterans Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-11-26 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-11-26","reason":"Thanksgiving Day"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-12-08 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-12-08","reason":"Immaculate Conception"}'::jsonb, null),

  ('asp_suspended_today', 'open_data', 'session', 40.7128, -74.0060, null, null, null,
   ('2026-12-25 23:59:59'::timestamp AT TIME ZONE 'America/New_York'),
   null, 0, 0, '{"suspension_date":"2026-12-25","reason":"Christmas Day"}'::jsonb, null)

on conflict ((meta->>'suspension_date'))
  where pin_type = 'asp_suspended_today'
do update set
  expires_at = excluded.expires_at,
  meta       = excluded.meta,
  updated_at = now();
