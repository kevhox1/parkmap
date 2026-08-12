/**
 * ingest-film-permits — Supabase Edge Function
 *
 * Fetches NYC OpenData film permit dataset (tg4x-b46p), filters to current/future
 * Parking-Held permits, maps fields to pins rows, and upserts via the partial unique
 * index pins_filming_permit_id_uidx ((meta->>'permit_id') WHERE pin_type='filming').
 *
 * Spec: docs/tier1-open-data-ingest-spec.md §3
 * Depends on: 02-pins-schema.sql + 02b-pins-ingest-indexes.sql applied.
 * Depends on (FT-16): 02g-ingest-runs.sql applied — see "Staleness detection" below.
 *
 * Secrets (set via `supabase secrets set` before deploying — never hardcode):
 *   SUPABASE_URL            — injected automatically by Supabase runtime
 *   SUPABASE_SERVICE_ROLE_KEY — injected automatically by Supabase runtime
 *   NYC_APP_TOKEN           — NYC OpenData app token for higher rate limits (optional)
 *
 * Invocation:
 *   POST https://<project-ref>.functions.supabase.co/ingest-film-permits
 *   Authorization: Bearer <service-role-key>
 *
 * Response: JSON { inserted, updated, skipped, errors[], upstreamProbeStatus, staleDays, upstreamLatestRowAt }
 *   upstreamProbeStatus is tri-state: "fresh" | "stale" | "probe_failed" — deliberately
 *   not a boolean (see the QA-fix note on fetchLatestUpstreamRowAt below).
 *
 * Staleness detection (FT-16, docs/qa/ft16-film-permit-feed-investigation.md):
 * The current/future filter below can legitimately match zero rows on any given day
 * (no permits happen to be scheduled) — that is NOT an error. What IS an error is the
 * upstream feed itself going dark: MOME stopping submission of new permit rows
 * entirely, which happened silently around 2026-05-07 for ~3 months with this function
 * running daily and never raising anything. This function now separately probes
 * `max(enteredon)` across the WHOLE upstream dataset (no current/future filter) on
 * every run, compares it to a staleness threshold, and writes every run's outcome to
 * `public.ingest_runs` so "the feed has been dry for N days" is a durable, queryable
 * fact instead of a state that only lives in ephemeral function logs.
 *
 * QA pass 1 (docs/qa/ft16-staleness-guard-qa.md) on the first cut of this guard flagged
 * two real defects, both fixed here: (1) a malformed-but-200 probe response used to
 * silently return null and read, once caught, as "verified fresh" — now every
 * non-usable outcome throws and lands in an explicit "probe_failed" state that is
 * never representable as "fine". (2) the probe fetch() had no timeout, so a hang could
 * block the invocation until the platform killed it, preventing the ingest_runs row
 * this PR is built around from ever being written — now bounded by PROBE_TIMEOUT_MS.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface SocrataPermit {
  eventid?: string;
  startdatetime?: string;
  enddatetime?: string;
  parkingheld?: string;
  borough?: string;
  latitude?: string;
  longitude?: string;
  category?: string;
  subcategoryname?: string;
  applicant?: string;
}

interface PinRow {
  pin_type: "filming";
  source: "open_data";
  lifespan: "session";
  lat: number;
  lng: number;
  segment_id: null;
  zone_id: string | null;
  author_id: null;
  expires_at: string;
  resolved_at: null;
  confirm_count: 0;
  dispute_count: 0;
  meta: {
    permit_id: string;
    production_name: string | null;
    film_office_url: null;
  };
  notes: null;
}

interface IngestResult {
  inserted: number;
  updated: number;
  skipped: number;
  errors: string[];
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SOCRATA_BASE = "https://data.cityofnewyork.us/resource/tg4x-b46p.json";
const PAGE_SIZE = 1000;
const GEOSEARCH_BASE = "https://geosearch.planninglabs.nyc/v2/search";
const GEOCODE_MIN_SCORE = 0.7;

// FT-16 staleness threshold, measured (not just inferred from "Daily" metadata) —
// per QA finding #4, this is checked against the dataset's own historical day-level
// gaps, not just a monthly-aggregate guess. Queried every consecutive gap between
// `enteredon` timestamps across the dataset's full history (2022-10 through the
// 2026-05 outage): the single largest gap anywhere is 41.96 days, but that one sits
// at the very start of the dataset's history (2022-10-20 -> 2022-12-01, immediately
// after the earliest row that exists at all) and reads as onboarding/ramp-up noise,
// not steady-state operation — there is nothing before it to compare cadence
// against. Excluding that one bootstrap artifact, the largest gap across ~3.5 years
// of mature operation is 5.01 days (2022-12), with every other outlier (holiday
// weeks in Dec 2023/2025, etc.) under 5 days too. 10 days is therefore ~2x the
// largest genuine historical lull ever observed in steady-state — real headroom, but
// not the 9x the first draft of this comment claimed. It still catches a real
// outage roughly 9x faster than the ~90 days it actually took to notice this one.
const STALENESS_THRESHOLD_DAYS = 10;

const VALID_BOROUGHS = new Set([
  "Manhattan",
  "Brooklyn",
  "Queens",
  "Bronx",
  "Staten Island",
]);

// City Hall, Manhattan — zone bounding box centroid for zone lookups.
// Zone assignment is done via DB query; this constant is unused but left for reference.
// const CITY_CENTROID = { lat: 40.7128, lng: -74.006 };

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function parseCoords(
  lat?: string,
  lng?: string
): { lat: number; lng: number } | null {
  if (!lat || !lng) return null;
  const latN = parseFloat(lat);
  const lngN = parseFloat(lng);
  if (isNaN(latN) || isNaN(lngN)) return null;
  // Basic sanity check: NYC bounding box
  if (latN < 40.4 || latN > 41.0 || lngN < -74.3 || lngN > -73.6) return null;
  return { lat: latN, lng: lngN };
}

async function geocode(
  address: string,
  borough: string
): Promise<{ lat: number; lng: number } | null> {
  try {
    const url = `${GEOSEARCH_BASE}?text=${encodeURIComponent(address)}&borough=${encodeURIComponent(borough)}&size=1`;
    const resp = await fetch(url, {
      headers: { "User-Agent": "WePark-ingest/1.0" },
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    const feature = data?.features?.[0];
    if (!feature) return null;
    const score: number = feature.properties?.confidence ?? 0;
    if (score < GEOCODE_MIN_SCORE) return null;
    const [lngN, latN] = feature.geometry.coordinates as [number, number];
    return parseCoords(String(latN), String(lngN));
  } catch {
    return null;
  }
}

async function lookupZoneId(
  supabase: ReturnType<typeof createClient>,
  lat: number,
  lng: number
): Promise<string | null> {
  const { data, error } = await supabase
    .from("zones")
    .select("id")
    .lte("lat_min", lat)
    .gte("lat_max", lat)
    .lte("lng_min", lng)
    .gte("lng_max", lng)
    .limit(1)
    .maybeSingle();
  if (error) return null;
  return data?.id ?? null;
}

async function fetchPermitPage(
  offset: number,
  appToken: string | undefined,
  now: Date
): Promise<SocrataPermit[]> {
  // Filter server-side: only future permits with parking held, ordered by eventid.
  // enddatetime >= now avoids pulling thousands of expired rows on each daily run.
  // Socrata `enddatetime` is a floating timestamp (no timezone), formatted like
  // `2026-03-05T01:00:00.000`. A comparison literal with a trailing `Z` (as
  // toISOString() produces) triggers a SoQL type-mismatch 400. Strip to seconds:
  // `YYYY-MM-DDTHH:MM:SS`.
  const nowIso = now.toISOString().slice(0, 19);
  const params = new URLSearchParams({
    $limit: String(PAGE_SIZE),
    $offset: String(offset),
    $where: `enddatetime >= '${nowIso}' AND parkingheld IS NOT NULL AND parkingheld != ''`,
    $order: "eventid ASC",
  });

  const headers: Record<string, string> = {
    "User-Agent": "WePark-ingest/1.0",
    Accept: "application/json",
  };
  if (appToken) {
    headers["X-App-Token"] = appToken;
  }

  const resp = await fetch(`${SOCRATA_BASE}?${params}`, { headers });
  if (!resp.ok) {
    throw new Error(
      `Socrata fetch failed: ${resp.status} ${resp.statusText}`
    );
  }
  return resp.json() as Promise<SocrataPermit[]>;
}

// FT-16 staleness probe timeout. A hung fetch() (TCP connects, no response ever
// arrives) would otherwise block the whole invocation until the Edge Function
// platform's own execution ceiling kills it — which also prevents the ingest_runs
// row from ever being written (QA finding #3). A bounded probe guarantees the
// try/catch around it always resolves in time for the durable-log write below to
// still run, degrading a stall to the ordinary probe_failed path instead.
const PROBE_TIMEOUT_MS = 8_000;

// FT-16: independent freshness probe. Deliberately does NOT reuse the
// current/future $where clause from fetchPermitPage — the whole point is to answer
// "is the upstream feed still receiving submissions at all?", which the filtered
// query cannot distinguish from "no permits currently match, which is normal."
//
// Throws (never silently returns a "can't tell" null) on any response that isn't a
// genuinely usable timestamp — non-2xx, network/abort error, or a 200 with a
// valid-JSON-but-wrong-shape body (empty array, missing/renamed `latest` field,
// unparseable date). QA finding #2 on the first cut of this function: a bare
// `return null` on a malformed-but-200 response was indistinguishable, once caught
// upstream, from "we verified freshness and it's fine" — that recreated this PR's
// own "legitimately quiet vs. silently broken" problem one layer up. This function
// already has a documented history of Socrata shape surprises (see the trailing-`Z`
// SoQL type-mismatch note on fetchPermitPage above), so treat every non-timestamp
// outcome as a loud failure, not a quiet null.
async function fetchLatestUpstreamRowAt(
  appToken: string | undefined
): Promise<Date> {
  const params = new URLSearchParams({ $select: "max(enteredon) as latest" });
  const headers: Record<string, string> = {
    "User-Agent": "WePark-ingest/1.0",
    Accept: "application/json",
  };
  if (appToken) headers["X-App-Token"] = appToken;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);
  let resp: Response;
  try {
    resp = await fetch(`${SOCRATA_BASE}?${params}`, {
      headers,
      signal: controller.signal,
    });
  } catch (err) {
    throw new Error(
      `Socrata freshness probe network error (possible timeout after ${PROBE_TIMEOUT_MS}ms): ${String(err)}`
    );
  } finally {
    clearTimeout(timeout);
  }

  if (!resp.ok) {
    throw new Error(
      `Socrata freshness probe failed: ${resp.status} ${resp.statusText}`
    );
  }

  const body = (await resp.json()) as unknown;
  if (!Array.isArray(body) || body.length === 0) {
    throw new Error(
      `Socrata freshness probe returned an unexpected shape (expected a non-empty array): ${JSON.stringify(body).slice(0, 200)}`
    );
  }
  const latest = (body[0] as { latest?: unknown })?.latest;
  if (typeof latest !== "string" || latest.length === 0) {
    throw new Error(
      `Socrata freshness probe row is missing a usable "latest" field: ${JSON.stringify(body[0]).slice(0, 200)}`
    );
  }
  const parsed = new Date(latest);
  if (isNaN(parsed.getTime())) {
    throw new Error(`Socrata freshness probe returned an unparseable date: "${latest}"`);
  }
  return parsed;
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (_req: Request): Promise<Response> => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const appToken = Deno.env.get("NYC_APP_TOKEN"); // optional

  if (!supabaseUrl || !serviceRoleKey) {
    return new Response(
      JSON.stringify({ error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY" }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }

  // Service-role client bypasses RLS — required for open_data inserts (§3, §4).
  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  const result: IngestResult = {
    inserted: 0,
    updated: 0,
    skipped: 0,
    errors: [],
  };

  const now = new Date();
  let offset = 0;
  let totalFetched = 0;

  try {
    // Paginate through all current/future parking-held permits.
    while (true) {
      const page = await fetchPermitPage(offset, appToken, now);
      if (page.length === 0) break;
      totalFetched += page.length;

      for (const permit of page) {
        const skippedByValidation = await processPermit(
          permit,
          supabase,
          now,
          result
        );
        if (skippedByValidation) result.skipped++;
      }

      if (page.length < PAGE_SIZE) break; // last page
      offset += PAGE_SIZE;
    }
  } catch (err) {
    result.errors.push(`Fatal fetch error: ${String(err)}`);
  }

  // ---------------------------------------------------------------------
  // FT-16: upstream freshness probe + durable run log.
  // Best-effort — a probe or log-write failure must never fail the whole
  // invocation (the main upsert work above already completed). The probe itself is
  // time-bounded (PROBE_TIMEOUT_MS, above) specifically so this block always finishes
  // in bounded time and the ingest_runs write below is always reached.
  //
  // Tri-state on purpose (QA finding #2): "we checked and it's fresh," "we checked
  // and it's stale," and "we could not check at all" are three genuinely different
  // facts and must never collapse into the same stored value. probeStatus starts
  // pessimistic ('probe_failed') and is only upgraded to 'fresh'/'stale' after a
  // successful, well-shaped probe response — never the other way around.
  // ---------------------------------------------------------------------
  type ProbeStatus = "fresh" | "stale" | "probe_failed";

  let upstreamLatestRowAt: Date | null = null;
  let staleDays: number | null = null;
  let probeStatus: ProbeStatus = "probe_failed";
  let probeError: string | null = null;

  try {
    upstreamLatestRowAt = await fetchLatestUpstreamRowAt(appToken);
    staleDays = Math.floor(
      (now.getTime() - upstreamLatestRowAt.getTime()) / 86_400_000
    );
    probeStatus = staleDays >= STALENESS_THRESHOLD_DAYS ? "stale" : "fresh";
  } catch (err) {
    probeError = String(err);
    probeStatus = "probe_failed";
  }

  if (probeStatus === "probe_failed") {
    // Loud on purpose — console.error surfaces distinctly from console.log/warn in
    // the Supabase Function logs dashboard and is the discoverable signal this
    // ticket asks for. A probe failure doesn't prove the feed is stale, but it must
    // be just as loud as a confirmed-stale feed — "couldn't tell" is never "fine."
    console.error(`ingest-film-permits freshness probe FAILED: ${probeError}`);
  } else if (probeStatus === "stale") {
    console.error(
      `ingest-film-permits STALE FEED: upstream tg4x-b46p (NYC Film Permits) has ` +
        `produced no new rows in ${staleDays} days (last enteredon=` +
        `${upstreamLatestRowAt?.toISOString()}). Threshold is ` +
        `${STALENESS_THRESHOLD_DAYS} days. See docs/qa/ft16-film-permit-feed-investigation.md.`
    );
  }

  try {
    const { error: logError } = await supabase.from("ingest_runs").insert({
      source: "film_permits",
      fetched_count: totalFetched,
      inserted_count: result.inserted,
      updated_count: result.updated,
      skipped_count: result.skipped,
      error_count: result.errors.length,
      errors: result.errors.slice(0, 20),
      upstream_latest_row_at: upstreamLatestRowAt?.toISOString() ?? null,
      probe_status: probeStatus,
      stale_days: staleDays,
      notes: probeError ? `freshness probe failed: ${probeError}` : null,
    });
    if (logError) {
      console.error(`ingest-film-permits failed to write ingest_runs row: ${logError.message}`);
    }
  } catch (err) {
    console.error(`ingest-film-permits failed to write ingest_runs row: ${String(err)}`);
  }

  console.log(
    `ingest-film-permits complete: fetched=${totalFetched} ` +
      `inserted=${result.inserted} updated=${result.updated} ` +
      `skipped=${result.skipped} errors=${result.errors.length} ` +
      `probeStatus=${probeStatus} staleDays=${staleDays ?? "unknown"}`
  );

  return new Response(
    JSON.stringify({
      ...result,
      totalFetched,
      // Tri-state on purpose — no boolean shorthand here. A boolean "upstreamStale"
      // field would re-introduce the exact ambiguity fixed in ingest_runs one layer
      // up: a reader seeing `false` couldn't tell "verified fresh" from "the probe
      // itself failed." Read upstreamProbeStatus, not an absence of staleness.
      upstreamProbeStatus: probeStatus,
      staleDays,
      upstreamLatestRowAt: upstreamLatestRowAt?.toISOString() ?? null,
    }),
    {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }
  );
});

// ---------------------------------------------------------------------------
// Per-permit processing
// Returns true if the permit was skipped (caller increments skipped counter).
// ---------------------------------------------------------------------------

async function processPermit(
  permit: SocrataPermit,
  supabase: ReturnType<typeof createClient>,
  now: Date,
  result: IngestResult
): Promise<boolean> {
  // 1. eventid must exist (dedup key).
  if (!permit.eventid || permit.eventid.trim() === "") return true;

  // 2. parkingheld must be non-empty (no parking hold = no map pin).
  if (!permit.parkingheld || permit.parkingheld.trim() === "") return true;

  // 3. Borough sanity check.
  if (permit.borough && !VALID_BOROUGHS.has(permit.borough)) return true;

  // 4. enddatetime must exist and be in the future.
  if (!permit.enddatetime) return true;
  const expiresAt = new Date(permit.enddatetime);
  if (isNaN(expiresAt.getTime()) || expiresAt <= now) return true;

  // 5. Resolve coordinates.
  let coords = parseCoords(permit.latitude, permit.longitude);
  if (!coords) {
    if (permit.parkingheld && permit.borough) {
      coords = await geocode(permit.parkingheld, permit.borough);
    }
    if (!coords) {
      // Log for manual review and skip.
      console.warn(`No coords for eventid=${permit.eventid} parkingheld="${permit.parkingheld}"`);
      return true;
    }
  }

  // 6. Zone lookup (best-effort; null is fine).
  const zoneId = await lookupZoneId(supabase, coords.lat, coords.lng);

  // 7. Build the pin row.
  const pin: PinRow = {
    pin_type: "filming",
    source: "open_data",
    lifespan: "session",
    lat: coords.lat,
    lng: coords.lng,
    segment_id: null,
    zone_id: zoneId,
    author_id: null,
    expires_at: expiresAt.toISOString(),
    resolved_at: null,
    confirm_count: 0,
    dispute_count: 0,
    meta: {
      permit_id: permit.eventid.trim(),
      production_name: permit.applicant?.trim() ?? null,
      film_office_url: null,
    },
    notes: null,
  };

  // 8. Upsert — keyed on partial unique index (meta->>'permit_id') WHERE pin_type='filming'.
  // Supabase JS client's upsert() does not support expression conflict targets directly,
  // so we use a raw RPC or the PostgREST upsert with onConflict.
  // PostgREST supports the expression index via the `on_conflict` query param when the
  // index name is supplied. We pass the index name as onConflict string.
  //
  // NOTE: Supabase JS v2 `.upsert(..., { onConflict: 'expression' })` passes the string
  // verbatim as ?on_conflict=<value> to PostgREST. PostgREST 12+ resolves named indexes
  // by index name. The index name is `pins_filming_permit_id_uidx`.
  // If PostgREST on this project is < 12 and doesn't support index-name resolution,
  // fall back to a raw SQL RPC (see comment below on the rpc path).
  //
  // We use count: 'exact' to distinguish insert (201) vs update (200) in the response.
  const { error, status } = await supabase
    .from("pins")
    .upsert(pin, {
      onConflict: "pins_filming_permit_id_uidx",
      ignoreDuplicates: false,
      count: "exact",
    });

  if (error) {
    // Fallback: try raw SQL upsert via rpc if the index-name path failed.
    const { error: rpcError } = await supabase.rpc("upsert_filming_pin", {
      p_lat: pin.lat,
      p_lng: pin.lng,
      p_zone_id: pin.zone_id,
      p_expires_at: pin.expires_at,
      p_meta: pin.meta,
    });
    if (rpcError) {
      result.errors.push(
        `eventid=${permit.eventid} upsert error: ${rpcError.message}`
      );
      return false; // not a validation skip — it was an error
    }
    // Assume update if fallback RPC succeeded (can't distinguish insert vs update from void).
    result.updated++;
    return false;
  }

  // status 201 = created (INSERT), 200 = OK (UPDATE via upsert).
  if (status === 201) {
    result.inserted++;
  } else {
    result.updated++;
  }

  return false; // not skipped
}
