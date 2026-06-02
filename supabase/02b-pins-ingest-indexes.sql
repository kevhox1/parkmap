-- WePark open-data ingest dedup indexes
-- Spec: docs/tier1-open-data-ingest-spec.md §5
-- Apply AFTER 02-pins-schema.sql. Safe to re-run (idempotent).
-- These indexes back the ON CONFLICT upsert targets used by the film-permit
-- and ASP-suspension ingest jobs. They are split into a separate file so ops
-- can apply them independently without re-running the full schema migration.

-- Filming dedup: one pin per NYC permit eventid
create unique index if not exists pins_filming_permit_id_uidx
  on public.pins ((meta->>'permit_id'))
  where pin_type = 'filming';

-- ASP suspension dedup: one pin per calendar date
create unique index if not exists pins_asp_suspension_date_uidx
  on public.pins ((meta->>'suspension_date'))
  where pin_type = 'asp_suspended_today';
