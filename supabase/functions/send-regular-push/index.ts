/**
 * send-regular-push — Supabase Edge Function
 *
 * Regulars S3 (docs/regulars-roadmap.md). New sibling to send-community-push. Fires on every new
 * `leaving_soon` pins row via the new `pins_invoke_send_regular_push` trigger
 * (supabase/08-regulars-push-trigger.sql) — UNCONDITIONALLY and IMMEDIATELY, the same instant the pin
 * is created, regardless of `regulars_head_start_seconds` (that column only ever affects the DELAYED
 * zone-wide fallthrough sweep, spec §2.8, still deferred to its own follow-up session; it has no effect
 * on this function's timing at all).
 *
 * Spec: docs/regulars-network-spec.md §2.9 ("send-regular-push — the new Edge Function"), §1.2a
 * (honest exclusivity), §0 decision 3 (a leaving_soon pin is unconditionally public the instant it
 * posts — sending its content to Regulars first discloses nothing a stranger couldn't already see by
 * opening the app).
 *
 * WHAT THIS FUNCTION DOES, ONE LINE: looks up the pin author's Regulars (`public.regular_edges`),
 * resolves each Regular's device token(s) by `user_id` (NOT by `zone_id` — a Regular should hear from
 * a specific person regardless of which zone they currently have open, spec §2.9), and sends each one
 * a VISIBLE, content-bearing APNs alert (title + body, not silent/content-available).
 *
 * WHY A VISIBLE PAYLOAD IS NOT A PRIVACY EXCEPTION (carried over from the spec verbatim, this is the
 * single most important invariant this file must never violate): a `leaving_soon` pin is unconditionally
 * public the instant it posts (spec decision 3) — any stranger browsing the zone board sees the exact
 * same position/copy a Regular's push would show. Sending it with visible content to consenting
 * Regulars discloses nothing beyond what a stranger can already see by opening the app — it just
 * arrives faster, via a push instead of a browse.
 *
 * THE PUSH BODY NEVER INCLUDES `pin_notes` TEXT — not now, not ever, by construction. `pins` and
 * `pin_notes` are two separate INSERT calls from the client (the note needs the pin's own generated id
 * as a foreign key, so it necessarily happens SECOND) — baking the note into this trigger-fired push
 * would race an insert that has not happened yet even if this function tried. This function does not
 * read `pin_notes` at all. The note (if any) is fetched live via `pin_notes`'s own Regulars-scoped
 * SELECT policy the moment the recipient opens the app or taps the notification — "the push's job is
 * to get attention, the app's job is to show content," the same shape send-community-push's silent
 * push already uses for its own on-device-resolved content.
 *
 * COPY-GENERATION AMBIGUITY, RESOLVED HERE (flagged for the PR description — the spec's own worked
 * example, "Kevin's leaving in 10 min, 15 min head start — Mott St near Prince," names a STREET-LEVEL
 * location descriptor this function cannot reproduce: `pins.segment_id` is an internal tile-index key
 * (e.g. "SOUTH_STREET_WHITEHALL_STREET_OLD_SLIP_E_9"), not a human-readable street name, and the
 * street/segment geometry that WOULD resolve it (tiles/*.json) is a client-side-only dataset — it is
 * never loaded into Supabase and this Edge Function has no access to it. Rather than guess at parsing
 * the segment_id slug (fragile, and risks a wrong/misleading location in a push a Regular can't easily
 * verify), this function uses `zones.name` instead — a real, already-public, already-existing column
 * (the same "coarse zone concept the UI already shows" send-community-push's own header already relies
 * on for its own privacy argument) as the location descriptor, and the pin author's `profiles.username`
 * (falling back to a generic "A Regular" if the author has no profile row yet) as the name. Exact push
 * copy is NOT a locked contract per the spec (§2.9 gives one illustrative example, not a literal
 * string) — this is a reasonable, defensible substitution, not a scope deviation, and is called out
 * explicitly here so `@qa-verifier`/Kevin can weigh in if street-level copy turns out to matter enough
 * to justify a future segment_id -> street-name resolution path (e.g. a small lookup table seeded from
 * the same tile pipeline, or moving resolution client-side via a follow-up local-notification
 * enhancement). No banned words anywhere in the generated copy (avoid/ticket/fine/evasion/dodge) —
 * verified by direct read of every string template below.
 *
 * Secrets: IDENTICAL names/loading pattern to send-community-push (same Supabase project, same APNs
 * credentials — Regulars pushes and zone pushes go out under the same APNs topic/team/key):
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — injected automatically by the Supabase runtime
 *   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_TOPIC, APNS_ENV — same secrets send-community-push
 *     already uses; nothing new to provision. See send-community-push/index.ts's own header for the
 *     full secret-by-secret description (deliberately not re-duplicated here).
 *
 * Invocation: POST https://<project-ref>.functions.supabase.co/send-regular-push
 *   Authorization: Bearer <service-role-key>
 *   Body: { "pin": { ...the full inserted pins row, via to_jsonb(NEW) in the trigger... } }
 *
 * FAIL-OPEN POSTURE (preserved verbatim from send-community-push, per the task's own instruction to
 * carry over every hard-won S11 property): a push failure of any kind here never breaks the pins
 * INSERT that triggered it — see 08-regulars-push-trigger.sql's own Vault-read-inside-exception-block
 * for the SQL-side half of this guarantee (the S11/PR#99 lesson: the Vault secret read must be INSIDE
 * the same exception-handling block as the HTTP dispatch, not just the dispatch itself). On this
 * function's own side: every branch below returns HTTP 200 with a `skipped`/`sent` field rather than a
 * non-2xx status for any "nothing to do" or "misconfigured" case, and pg_net's invocation is
 * fire-and-forget from the trigger's perspective regardless — this function's response can never
 * itself roll back the INSERT.
 *
 * Dead-token cleanup / batching / JWT signing: delegated entirely to `../_shared/apns.ts` (Regulars S3
 * extraction) — same hardened code send-community-push now also calls, not a fork of it.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  APNS_HOSTS,
  DeviceTokenRow,
  ApnsEnv,
  getApnsJwt,
  sendInChunks,
} from "../_shared/apns.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Subset of the `pins` row shape this function actually reads. The trigger sends the full row
 * (to_jsonb(NEW)), so this is deliberately a partial interface — extra fields (including `notes`,
 * which this function must NEVER read — see the file header) are ignored. */
interface PinRecord {
  id: string;
  pin_type: string;
  author_id: string | null;
  segment_id: string | null;
  zone_id: string | null;
  leaving_minutes: number | null;
  regulars_head_start_seconds: number | null;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Hard cap on how many device_push_tokens rows a single invocation will fan out to. Unlike
// send-community-push's zone-wide fan-out, a Regulars list is a handful of people by design (spec
// §1.1 — "5 people on my block") and the spec explicitly declines to enforce a hard schema cap on
// Regulars count (§1.3). This is a safety ceiling against a pathological outlier account, not a
// tuned-to-real-load number — deliberately generous (matches send-community-push's own 500) since a
// legitimately large Regulars list should never be silently truncated.
const MAX_TOKENS_PER_INVOCATION = 500;

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request): Promise<Response> => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const apnsKeyId = Deno.env.get("APNS_KEY_ID");
  const apnsTeamId = Deno.env.get("APNS_TEAM_ID");
  const apnsPrivateKey = Deno.env.get("APNS_PRIVATE_KEY");
  const apnsTopic = Deno.env.get("APNS_TOPIC");
  const apnsEnvRaw = (Deno.env.get("APNS_ENV") ?? "sandbox").trim().toLowerCase();

  if (!supabaseUrl || !serviceRoleKey) {
    return new Response(
      JSON.stringify({ error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY" }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
  if (!apnsKeyId || !apnsTeamId || !apnsPrivateKey || !apnsTopic) {
    // Loud, but does not throw — a misconfigured-secrets deploy must not crash the Postgres trigger
    // that invoked this function (fail-open posture, matching send-community-push's identical
    // handling and 08-regulars-push-trigger.sql's own exception-block guarantee).
    console.error(
      "send-regular-push: missing one or more APNS_KEY_ID/APNS_TEAM_ID/APNS_PRIVATE_KEY/APNS_TOPIC secrets — skipping."
    );
    return new Response(
      JSON.stringify({ error: "APNs secrets not configured", sent: 0, skipped: true }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }
  if (apnsEnvRaw !== "sandbox" && apnsEnvRaw !== "production") {
    console.error(`send-regular-push: invalid APNS_ENV "${apnsEnvRaw}" — falling back to sandbox.`);
  }
  const apnsEnv: ApnsEnv = apnsEnvRaw === "production" ? "production" : "sandbox";

  let payload: { pin?: PinRecord };
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const pin = payload?.pin;
  if (!pin || !pin.id || !pin.pin_type) {
    return new Response(JSON.stringify({ error: "Missing pin in request body" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Defense-in-depth: the pins_invoke_send_regular_push trigger (08-regulars-push-trigger.sql) already
  // gates on pin_type = 'leaving_soon' via its WHEN clause — re-check here so this function is safe to
  // invoke directly (e.g. a manual test call) too, same convention as send-community-push's own
  // source/lifespan re-check.
  if (pin.pin_type !== "leaving_soon") {
    return new Response(
      JSON.stringify({ skipped: true, reason: "not a leaving_soon pin", sent: 0 }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }
  if (!pin.author_id) {
    // Should be unreachable (pins.author_id is not null in the live schema) — defensive only.
    return new Response(JSON.stringify({ skipped: true, reason: "author_id is null", sent: 0 }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // Service-role client bypasses RLS — required. regular_edges' own RLS only lets either PARTY read a
  // row (auth.uid() in (low_user_id, high_user_id)); this function has no auth.uid() of its own (it is
  // not an authenticated user session), so it must read as service-role, exactly like
  // send-community-push already does for the RLS-closed device_push_tokens table.
  const { data: edgeRows, error: edgesError } = await supabase
    .from("regular_edges")
    .select("low_user_id, high_user_id")
    .or(`low_user_id.eq.${pin.author_id},high_user_id.eq.${pin.author_id}`);

  if (edgesError) {
    console.error(`send-regular-push: regular_edges query failed: ${edgesError.message}`);
    return new Response(JSON.stringify({ error: edgesError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const regularIds = (edgeRows ?? [])
    .map((r: { low_user_id: string; high_user_id: string }) =>
      r.low_user_id === pin.author_id ? r.high_user_id : r.low_user_id
    )
    // Defensive de-dupe: the canonical low/high schema (§S1-2) makes a duplicate pair structurally
    // impossible, but a de-dupe here costs nothing and guards against any future relaxation of that
    // constraint silently double-sending to the same person.
    .filter((id: string, idx: number, arr: string[]) => arr.indexOf(id) === idx);

  if (regularIds.length === 0) {
    console.log(`send-regular-push: pin ${pin.id} author ${pin.author_id} has zero Regulars — nothing to send.`);
    return new Response(JSON.stringify({ sent: 0, pin_id: pin.id, regulars: 0 }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Targeting by user_id, NOT zone_id (spec §2.9) — a Regular should hear about this specific person
  // regardless of which zone they currently have open.
  const { data: tokens, error: tokensError } = await supabase
    .from("device_push_tokens")
    .select("id, apns_token, environment")
    .in("user_id", regularIds)
    .eq("environment", apnsEnv)
    .limit(MAX_TOKENS_PER_INVOCATION);

  if (tokensError) {
    console.error(`send-regular-push: device_push_tokens query failed: ${tokensError.message}`);
    return new Response(JSON.stringify({ error: tokensError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const deviceTokens = (tokens ?? []) as DeviceTokenRow[];
  if (deviceTokens.length === 0) {
    console.log(
      `send-regular-push: no ${apnsEnv} tokens among ${regularIds.length} Regular(s) for pin=${pin.id} — nothing to send.`
    );
    return new Response(
      JSON.stringify({ sent: 0, pin_id: pin.id, regulars: regularIds.length }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }

  // Best-effort cosmetic lookups — a failure here degrades the push's COPY, never blocks sending it.
  // Never trust/require these: worst case is a generic "A Regular" / omitted zone name, not a dropped
  // push. Fetched via the service-role client (bypasses RLS, same as every other read in this
  // function); profiles/zones are both broadly public-read tables already (profiles per the standing
  // username-is-public convention; zones per the community-2.0 zone-picker UI), so this is not a new
  // access path, just a service-role convenience over an anon-readable table.
  let authorName = "A Regular";
  let zoneName: string | null = null;
  try {
    const { data: authorProfile } = await supabase
      .from("profiles")
      .select("username")
      .eq("id", pin.author_id)
      .maybeSingle();
    if (authorProfile?.username) authorName = authorProfile.username as string;
  } catch (err) {
    console.error(`send-regular-push: profiles lookup failed (non-fatal): ${String(err)}`);
  }
  if (pin.zone_id) {
    try {
      const { data: zoneRow } = await supabase
        .from("zones")
        .select("name")
        .eq("id", pin.zone_id)
        .maybeSingle();
      if (zoneRow?.name) zoneName = zoneRow.name as string;
    } catch (err) {
      console.error(`send-regular-push: zones lookup failed (non-fatal): ${String(err)}`);
    }
  }

  let jwt: string;
  try {
    jwt = await getApnsJwt(apnsKeyId, apnsTeamId, apnsPrivateKey);
  } catch (err) {
    console.error(`send-regular-push: failed to sign APNs provider JWT: ${String(err)}`);
    return new Response(JSON.stringify({ error: `JWT signing failed: ${String(err)}` }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const host = APNS_HOSTS[apnsEnv];

  const leavingMinutes = typeof pin.leaving_minutes === "number" ? pin.leaving_minutes : null;
  const headStartMinutes =
    typeof pin.regulars_head_start_seconds === "number"
      ? Math.round(pin.regulars_head_start_seconds / 60)
      : null;

  // Visible, content-bearing alert — the deliberate, consensual friend disclosure the spec's privacy
  // section documents (§2.9). Title/body only; NEVER pin_notes text (see file header). Data fields
  // alongside `aps` mirror send-community-push's own pin_id/segment_id/zone_id convention so the client
  // can deep-link/refresh exactly the same way it already does for a zone push.
  const title = `${authorName} is leaving soon`;
  const bodyParts: string[] = [];
  if (leavingMinutes !== null) bodyParts.push(`${leavingMinutes} min out`);
  if (headStartMinutes !== null) bodyParts.push(`${headStartMinutes} min head start for your Regulars`);
  if (zoneName) bodyParts.push(zoneName);
  const body = bodyParts.length > 0 ? bodyParts.join(" — ") : "Leaving soon — tap to see the spot.";

  const outcomes = await sendInChunks(deviceTokens, host, jwt, apnsTopic, {
    pushType: "alert",
    priority: "10",
    body: {
      aps: {
        alert: { title, body },
        sound: "default",
      },
      pin_type: pin.pin_type,
      pin_id: pin.id,
      author_id: pin.author_id,
      segment_id: pin.segment_id,
      zone_id: pin.zone_id,
      leaving_minutes: pin.leaving_minutes,
      regulars_head_start_seconds: pin.regulars_head_start_seconds,
    },
  });

  const sent = outcomes.filter((o) => o.ok).length;
  const failed = outcomes.filter((o) => !o.ok);
  const deadTokenIds = outcomes.filter((o) => o.deleted).map((o) => o.tokenId);

  if (deadTokenIds.length > 0) {
    const { error: deleteError } = await supabase
      .from("device_push_tokens")
      .delete()
      .in("id", deadTokenIds);
    if (deleteError) {
      console.error(
        `send-regular-push: failed to delete ${deadTokenIds.length} dead token row(s): ${deleteError.message}`
      );
    } else {
      console.log(`send-regular-push: deleted ${deadTokenIds.length} dead token row(s) (410/BadDeviceToken).`);
    }
  }

  for (const o of failed) {
    if (!o.deleted) {
      console.error(
        `send-regular-push: APNs send failed for token ${o.tokenId}: status=${o.status} error=${o.error}`
      );
    }
  }

  console.log(
    `send-regular-push complete: pin=${pin.id} author=${pin.author_id} env=${apnsEnv} ` +
      `regulars=${regularIds.length} candidates=${deviceTokens.length} sent=${sent} failed=${failed.length} deadTokensRemoved=${deadTokenIds.length}`
  );

  return new Response(
    JSON.stringify({
      pin_id: pin.id,
      author_id: pin.author_id,
      environment: apnsEnv,
      regulars: regularIds.length,
      candidates: deviceTokens.length,
      sent,
      failed: failed.length,
      deadTokensRemoved: deadTokenIds.length,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
});
