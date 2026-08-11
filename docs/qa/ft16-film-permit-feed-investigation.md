# FT-16: NYC Film Permit Feed Investigation

**Investigation date:** 2026-08-11
**Investigator:** @backend-data
**Status:** Root cause confirmed (matches orchestrator's preliminary finding). Fix implemented,
not yet applied to production — see "Deployment" at the end.

---

## 1. Summary

The orchestrator's preliminary finding (recorded in `docs/field-testing-log.md`, FT-16 entry) is
**confirmed, independently, with additional evidence**: NYC OpenData's Film Permits dataset
(Socrata `tg4x-b46p`) stopped receiving new permit submissions around **2026-05-07/12** and has not
produced a single new row since — a genuine ~3-month upstream outage, not a retirement, not a
deliberate publishing delay, and not a bug in our ingest function's filter logic.

No replacement dataset exists for this specific signal (individual, day-to-day film-shoot permits
with parking holds). The chosen fix is to **keep the ingest function and its daily cron as-is**
(the filter logic is correct) and add a **durable, loud staleness detector** so a future outage of
this kind is caught in days, not months. Full design in §5 and in
`docs/tier1-open-data-ingest-spec.md` §3.9.

---

## 2. Confirming the orchestrator's finding

Independent Socrata queries against `https://data.cityofnewyork.us/resource/tg4x-b46p.json`,
run 2026-08-11:

```
$select=max(startdatetime),max(enteredon),count(*)
→ max(startdatetime) = 2026-05-12T12:02:00.000
  max(enteredon)      = 2026-05-07T17:55:08.000
  count(*)             = 18501
```

Dataset metadata (`https://data.cityofnewyork.us/api/views/tg4x-b46p.json`):

```
rowsUpdatedAt   = 1786390230  →  2026-08-10 19:30:30 UTC (yesterday, relative to this investigation)
attribution     = Mayor's Office of Media and Entertainment (MOME)
Update.Automation      = "Yes"
Update.Update Frequency = "Daily"
```

`rowsUpdatedAt` advancing to "yesterday" while the row data itself (`max(startdatetime)`,
`max(enteredon)`) is frozen at May confirms the orchestrator's read: the Socrata **asset** is being
touched/republished (e.g. a metadata refresh or a no-op re-save by NYC's automation), but no **new
rows** are landing. This is exactly the kind of signal that makes an outage invisible if you're only
glancing at "last updated" timestamps.

Monthly submission volume (`enteredon`, grouped by month) shows a hard cliff, not a gradual decline
or a seasonal dip:

| Month | New permits submitted (`enteredon`) |
|---|---|
| 2026-01 | 271 |
| 2026-02 | 256 |
| 2026-03 | 446 |
| 2026-04 | 483 |
| 2026-05 (partial, through the 7th) | 74 |
| 2026-06 | **0** |
| 2026-07 | **0** |
| 2026-08 (through the 10th) | **0** |

A steady ~250–500/month cadence stops dead after May 7, 2026. This shape (abrupt cliff, not decay)
is inconsistent with normal seasonal variation in film-permit volume and consistent with an upstream
pipeline break on NYC's side.

Zero rows have ever matched E 2nd St (Kevin's FT-15 filming report location), consistent with the
orchestrator's finding — not because that block is never permitted, but because nothing from the
last ~3 months (which is when this specific August report would have needed to be entered) is in
the dataset at all.

**Verdict: confirmed, no correction needed to the orchestrator's framing.**

---

## 3. Ruled out: intentional publishing delay

Before accepting "the feed genuinely broke," I checked a plausible alternative: some open-data
feeds intentionally embargo sensitive location data for a period (e.g., for security/privacy
reasons) before publishing. A general web search surfaced an unverified claim along these lines
("delays posting by 3 months, a schedule agreed upon with City Council") — three months is
suspiciously close to today's gap, so this needed to be checked carefully rather than taken at
face value or dismissed.

This claim does **not** hold up against the data:

- NYC's own dataset metadata/description makes no mention of any embargo or publishing delay.
- A BetaNYC technical write-up on processing this exact dataset makes no mention of one either.
- Directly measuring the lag between a permit's submission (`enteredon`) and its scheduled start
  (`startdatetime`) for the most recent rows before the cutoff shows same-week turnaround, not a
  3-month embargo:

  ```
  eventid=943550  enteredon=2026-05-07T17:55  startdatetime=2026-05-12T12:02   (5 days)
  eventid=943505  enteredon=2026-05-07T15:53  startdatetime=2026-05-11T06:00   (4 days)
  eventid=942682  enteredon=2026-05-06T10:33  startdatetime=2026-05-07T14:00   (1 day)
  ```

  If NYC held rows back for 3 months before publishing, every currently-visible row's
  `startdatetime` would already be months in the past relative to its `enteredon` — it is not; the
  lead time is days, matching how film permits actually work (short-notice location holds).

**Verdict: no intentional delay. The dataset simply stopped receiving new submissions.** This
also means the current/future filter in `fetchPermitPage()` was never structurally broken — it
worked correctly for years (steady several-hundred-per-month volume through April 2026) and would
resume working the moment NYC resumes publishing.

---

## 4. Searching for a replacement / successor feed

Checked via the Socrata catalog API on `data.cityofnewyork.us` (note: `api.us.socrata.com/api/catalog/v1`
returned non-JSON as flagged in the task; `data.cityofnewyork.us/api/catalog/v1?q=...` and
`data.cityofnewyork.us/api/views/{id}.json` both worked and were used instead):

```
GET https://data.cityofnewyork.us/api/catalog/v1?domains=data.cityofnewyork.us&q=film
```

Results — no successor asset. Everything MOME-adjacent is either historical/static or unrelated to
active permits:

| id | name | last updated |
|---|---|---|
| `tg4x-b46p` | Film Permits (the dataset in question) | 2026-08-10 (asset touch, not new rows — see §2) |
| `qb3k-n8mm` | Filming Locations (Scenes from the City) | 2018 (static) |
| `9ixa-eggw` | Recording Studios | 2018 (static) |
| `bvna-6j7v` | Production office space | 2018 (static) |
| `tvpp-9vvx` | NYC Permitted Event Information | 2026-08-10, **actively live** |
| `bkfu-528j` | NYC Permitted Event Information - Historical | 2026-07-28 |

`tvpp-9vvx` looked promising at first glance — actively updating, and its description explicitly
mentions "Permitted Film Events." Checked in detail:

- Publisher is **Office of Citywide Event Coordination and Management (CECM)**, not MOME.
- `event_type` breakdown: dominated by `Sport - Youth` (14,861), `Sport - Adult` (6,806),
  `Special Event` (5,154); the closest film-adjacent categories are `Production Event` (29 rows)
  and `Theater Load in and Load Outs` (9 rows) — no row has `event_type` literally containing
  "Film".
- Sampling `Production Event` rows shows this is a general **Street Activity Permit Office (SAPO)**
  street-closure category, not MOME film-shoot permits specifically — e.g. `"Barnard College
  student move in"`, `"CNC EVENT"`, `"CIPRIANI EVENTS"` alongside genuine production-adjacent
  entries. Its own description also states it only covers "approved event applications that will
  occur within the next month" and that "Permitted Film Events only reflect those permits which
  will impact one or more streets for at least five days" — i.e. even the subset of this feed that
  *is* film-related would silently exclude the majority of MOME permits (typical duration:
  single-day, as shown in §3), which would misrepresent the `filming` pin type if substituted.

**Verdict: no viable replacement feed for individual film-shoot permits.** `tg4x-b46p` remains the
only source that matches WePark's `filming` pin_type semantics; there is nothing better to repoint
to today.

---

## 5. Decision and implementation

Per the three options framed in the task (repoint / fix the function / disable the job):

- **Repoint: rejected.** No suitable replacement exists (§4).
- **Disable the job: rejected.** The filter logic itself is not defective (§3) — it is correctly
  returning zero rows against a genuinely dry upstream feed. Disabling the cron would trade one
  invisible-failure mode (silent 3-month outage) for another (silently-off cron that nobody
  remembers to re-enable when NYC resumes publishing). The daily invocation cost is negligible (one
  small Socrata query).
- **Fix the function: chosen.** Not a fix to the filter (nothing wrong there) — a fix to the
  actual defect this ticket is about: the total absence of any signal distinguishing "correctly
  empty" from "silently broken."

### What changed

1. **`supabase/02g-ingest-runs.sql`** (new migration) — a small `public.ingest_runs` table:
   durable, source-tagged run history (`fetched_count`, `inserted_count`/`updated_count`/
   `skipped_count`/`error_count`, `upstream_latest_row_at`, `stale`, `stale_days`) written on every
   invocation. RLS enabled with **no policies** (deny-all to anon/authenticated — this is an
   internal ops table with no owning user; the service-role key used by the Edge Function bypasses
   RLS for writes). Generic across future ingest jobs (`source` is free text), not filming-specific.

2. **`supabase/functions/ingest-film-permits/index.ts`** — on every run, independent of the
   existing current/future filter:
   - Probes `$select=max(enteredon)` against the **whole** upstream dataset (no filter) to measure
     "has MOME submitted anything recently at all?"
   - If that timestamp is ≥ `STALENESS_THRESHOLD_DAYS` (10) old, logs via `console.error` (a
     distinct, higher-severity log line in the Supabase Functions dashboard than the routine
     `console.log` summary) and marks the run `stale = true`.
   - Writes one row to `ingest_runs` every invocation, success or no-op.
   - Returns `upstreamStale`, `staleDays`, `upstreamLatestRowAt` in the JSON response, so a manual
     `curl` (already documented in the deploy runbook, §9 Step 4) surfaces staleness immediately.
   - All of the above is best-effort and wrapped so a probe or logging failure can never break the
     main upsert path.

3. **`docs/tier1-open-data-ingest-spec.md` §3.9** (new section) — the spec-of-record for this
   mechanism, plus a new deployment Step 7 for `02g-ingest-runs.sql`.

**Filename note:** originally authored as `02f-ingest-runs.sql`; renamed to `02g-ingest-runs.sql`
after PR #69 (FT-15 Stream A, `supabase/02f-block-scoped-restrictions.sql`) claimed the `02f`
ordinal first. The two migrations are independent — `02g-ingest-runs.sql` has no dependency on
`02f-block-scoped-restrictions.sql` (different tables, no cross-references) — so they can be applied
in either order, or this one applied without #69 ever landing.

Threshold rationale: NYC's own metadata claims daily automation, and observed submission-to-start
lead time is single-digit days (§3). 10 days gives headroom against a slow weekend/holiday while
catching a real outage roughly 9x faster than the ~90 days it took to notice this one.

### Why this is proportionate (not over-engineered)

Per the task's own framing: this layer being empty is a missing map decoration, not a wrong
parking-legality determination (contrast with TF2-19, where an incomplete pull shipped tiles that
told drivers a metered/no-standing block was free). A `console.error` + a queryable table is a loud,
discoverable signal appropriate to that severity — no paging/alerting integration, no retry
scheduler, no second cron job was added.

---

## 6. Consequence for FT-15

Confirmed: with `tg4x-b46p` dry, the crowd-report path speced in FT-15 (block-scoped restriction
override from user-submitted paper-sign reports) is not a "gap-filler" alongside open-data
corroboration — for the `filming` pin type, it is currently **the only signal** WePark has. FT-15's
`permit_id` open-data corroboration must stay strictly optional per the existing FT-15 plan; nothing
in this investigation changes that recommendation, it just adds hard evidence for why it matters
right now.

---

## 7. Deployment (not yet applied to production)

Per `.claude/TEAM.md`, schema changes get QA before production; per this task's constraints, nothing
here has been applied to the live Supabase project (`jiispshyqerscdoferaw`). Kevin applies after QA:

1. Apply `supabase/02g-ingest-runs.sql` via the Supabase SQL Editor (new step 7 in
   `docs/tier1-open-data-ingest-spec.md` §9). No ordering dependency on `02f-block-scoped-restrictions.sql`
   (PR #69) — apply in either order.
2. Redeploy `ingest-film-permits` (`supabase functions deploy ingest-film-permits --project-ref
   jiispshyqerscdoferaw`).
3. Manually invoke once and confirm the response includes `upstreamStale: true` and a `staleDays`
   in the ~95+ range (expected, given the confirmed ~3-month outage) — this is the "it's alarming
   correctly" smoke test, not a sign anything is broken.
4. No client changes required — this PR does not touch any RPC name, table both apps already read,
   or PostgREST contract PWA/iOS depend on. `@pwa-maintainer` and `@ios-engineer` do not need to do
   anything for this specific change. (FT-15's separate report-flow work, tracked independently, is
   what will eventually give iOS a UI for the crowd-sourced `filming` signal.)
