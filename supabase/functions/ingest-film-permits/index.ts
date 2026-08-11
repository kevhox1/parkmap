/**
 * ingest-film-permits — Supabase Edge Function
 *
 * Fetches NYC OpenData film permit dataset (tg4x-b46p), filters to current/future
 * Parking-Held permits, maps fields to pins rows, and upserts via the partial unique
 * index pins_filming_permit_id_uidx ((meta->>'permit_id') WHERE pin_type='filming').
 *
 * Spec: docs/tier1-open-data-ingest-spec.md §3
 * Depends on: 02-pins-schema.sql + 02b-pins-ingest-indexes.sql applied.
 * Depends on (FT-16): 02f-ingest-runs.sql applied — see "Staleness detection" below.
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
 * Response: JSON { inserted, updated, skipped, errors[], upstreamStale, staleDays, upstreamLatestRowAt }
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

// FT-16 staleness threshold: NYC's own dataset metadata claims "Update Frequency:
// Daily" with automation enabled, and the field-observed lead time between a permit's
// `enteredon` and its `startdatetime` is typically single-digit days (verified via a
// live probe during the FT-16 investigation — see docs/qa/ft16-film-permit-feed-investigation.md).
// 10 days is generous headroom above that normal cadence (avoids false alarms on a
// slow weekend/holiday) while catching a real outage roughly 9x faster than the ~90
// days it actually took us to notice this one.
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

// FT-16: independent freshness probe. Deliberately does NOT reuse the
// current/future $where clause from fetchPermitPage — the whole point is to answer
// "is the upstream feed still receiving submissions at all?", which the filtered
// query cannot distinguish from "no permits currently match, which is normal."
async function fetchLatestUpstreamRowAt(
  appToken: string | undefined
): Promise<Date | null> {
  const params = new URLSearchParams({ $select: "max(enteredon) as latest" });
  const headers: Record<string, string> = {
    "User-Agent": "WePark-ingest/1.0",
    Accept: "application/json",
  };
  if (appToken) headers["X-App-Token"] = appToken;

  const resp = await fetch(`${SOCRATA_BASE}?${params}`, { headers });
  if (!resp.ok) {
    throw new Error(
      `Socrata freshness probe failed: ${resp.status} ${resp.statusText}`
    );
  }
  const rows = (await resp.json()) as Array<{ latest?: string }>;
  const latest = rows[0]?.latest;
  if (!latest) return null;
  const parsed = new Date(latest);
  return isNaN(parsed.getTime()) ? null : parsed;
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
  // invocation (the main upsert work above already completed).
  // ---------------------------------------------------------------------
  let upstreamLatestRowAt: Date | null = null;
  let staleDays: number | null = null;
  let isStale = false;
  let probeError: string | null = null;

  try {
    upstreamLatestRowAt = await fetchLatestUpstreamRowAt(appToken);
    if (upstreamLatestRowAt) {
      staleDays = Math.floor(
        (now.getTime() - upstreamLatestRowAt.getTime()) / 86_400_000
      );
      isStale = staleDays >= STALENESS_THRESHOLD_DAYS;
    }
  } catch (err) {
    probeError = String(err);
  }

  if (probeError) {
    // Loud on purpose — console.error surfaces distinctly from console.log/warn in
    // the Supabase Function logs dashboard and is the discoverable signal this
    // ticket asks for. A probe failure doesn't prove the feed is stale, so we don't
    // set isStale here — but it IS worth flagging for manual follow-up.
    console.error(`ingest-film-permits freshness probe FAILED: ${probeError}`);
  } else if (isStale) {
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
      stale: isStale,
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
      `upstreamStale=${isStale} staleDays=${staleDays ?? "unknown"}`
  );

  return new Response(
    JSON.stringify({
      ...result,
      totalFetched,
      upstreamStale: isStale,
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
