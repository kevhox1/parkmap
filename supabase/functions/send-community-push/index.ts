/**
 * send-community-push — Supabase Edge Function
 *
 * Phase 4b of Community 2.0 (build 20, session S11). Fires on a new ephemeral crowd `pins` row
 * (source='crowd', lifespan='ephemeral', zone_id not null) via the `pins_invoke_send_community_push`
 * trigger (supabase/04-community-push-trigger.sql). Looks up every device subscribed to the pin's
 * zone in `public.device_push_tokens` and sends each one a SILENT (content-available) APNs push.
 *
 * Spec: docs/community-2.0-reconciliation-spec.md §2.9 ("Privacy-preserving design note") and §3
 * Phase 4 ("APNs pipeline"). The privacy invariant this function exists to uphold: the server NEVER
 * learns which blockface (segment_id) any device's parked car is on — it only knows which zone a
 * device is subscribed to (device_push_tokens.zone_id, the same coarse, already-public zone concept
 * the UI already shows). This function's payload therefore carries pin_type/segment_id/pin_id/zone_id
 * but ZERO user-facing alert content — the CLIENT (WeParkApp.swift / NotificationScheduler.swift,
 * Phase 4 iOS work) is the only party that ever knew its own parked segment, and it is the one that
 * decides — entirely on-device — whether the pin's segment_id matches ParkedCar.segmentId and, if so,
 * surfaces a local UNUserNotificationCenter notification. A silent push with no alert dict never
 * displays anything on its own.
 *
 * Secrets (set via `supabase secrets set` or the Dashboard before deploying — never hardcode; see PR
 * description for the exact deploy order):
 *   SUPABASE_URL              — injected automatically by the Supabase runtime
 *   SUPABASE_SERVICE_ROLE_KEY — injected automatically by the Supabase runtime
 *   APNS_KEY_ID               — Apple APNs Auth Key ID (Key ID CMG824J6L3 per the roadmap S11 row)
 *   APNS_TEAM_ID               — Apple Developer Team ID (ZAA4UCS6CH)
 *   APNS_PRIVATE_KEY          — full contents of the .p8 file (PEM, PKCS8 EC private key), including
 *                                the `-----BEGIN PRIVATE KEY-----`/`-----END PRIVATE KEY-----` lines.
 *                                Lives ONLY on Kevin's Mac + as a Supabase secret — never in this repo.
 *   APNS_TOPIC                — bundle id used as the apns-topic header (com.kevinhoxha.wepark)
 *   APNS_ENV                  — 'sandbox' | 'production', default 'sandbox' if unset. See the
 *                                "environment selection" note below for exactly how this is used.
 *
 * Invocation: POST https://<project-ref>.functions.supabase.co/send-community-push
 *   Authorization: Bearer <service-role-key>
 *   Body: { "pin": { ...the full inserted pins row, via to_jsonb(NEW) in the trigger... } }
 *
 * Environment selection (design decision, not stated ambiguously in the spec — documented here):
 * `device_push_tokens.environment` is authoritative per-token (a device registers with the actual
 * APNs environment its build's provisioning profile uses — Xcode debug builds are 'sandbox', TestFlight
 * and App Store builds are 'production'). Sending a sandbox-provisioned token to the production APNs
 * host (or vice versa) always fails with BadDeviceToken, which would otherwise cause this function to
 * wrongly delete a perfectly valid token (see the 410/BadDeviceToken handling below). To avoid that,
 * APNS_ENV is used as BOTH (a) a query filter — only tokens whose stored `environment` column equals
 * APNS_ENV are fetched for this invocation — and (b) the APNs host selector for every request sent.
 * This means a project only ever pushes to one environment's tokens per deployment; if/when both
 * sandbox (internal dogfood builds) and production (TestFlight/App Store) tokens need to receive
 * pushes simultaneously, the fix is to loop over both environments and both hosts here, not to trust
 * a client-controllable environment value blindly. Not needed yet — S12 (iOS registration) hasn't
 * shipped, so no tokens exist of either kind. Default 'sandbox' matches "no APNS_ENV secret set yet"
 * being the expected initial state, not a claim about which environment is more common in production.
 *
 * Batching / fan-out cap: see MAX_TOKENS_PER_INVOCATION below and `../_shared/apns.ts`'s CHUNK_SIZE
 * (the concurrency-per-batch constant moved there in the S3 extraction, unchanged in value).
 *
 * Dead-token cleanup: APNs 410 (Unregistered) or a 400 with reason "BadDeviceToken" both mean the
 * token is permanently invalid — the row is deleted from device_push_tokens so it never wastes a
 * fan-out slot again. Every other non-2xx response is logged and left alone (could be transient,
 * config-related, or rate-limiting — not evidence the *token* itself is bad).
 *
 * REFACTOR NOTE (Regulars S3, docs/regulars-roadmap.md): the APNs JWT signing/caching and the raw
 * send-and-classify-response logic that used to live inline in this file now live in
 * `../_shared/apns.ts`, shared with the new sibling `send-regular-push` function. This is a
 * BEHAVIOR-PRESERVING extraction only — the exact same body/headers this function has always sent are
 * still constructed here (see `sendOnePush`'s payload dict in the main handler below) and handed to
 * the shared `sendInChunks` unchanged; nothing about the wire format, dead-token rule, or fail-open
 * posture changed. See `_shared/apns.ts`'s own header for the full reasoning and the note that this
 * source change has no production effect until send-community-push is explicitly re-deployed.
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
 * (to_jsonb(NEW)) so this is deliberately a partial interface — extra fields are ignored. */
interface PinRecord {
  id: string;
  pin_type: string;
  source: string;
  lifespan: string;
  segment_id: string | null;
  zone_id: string | null;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Hard cap on how many device_push_tokens rows a single invocation will fan out to. Ephemeral crowd
// pins are zone-scoped and zones are small (three NYC neighborhoods today, §2.3) — this is a safety
// ceiling against a runaway zone (or a future much-larger zone set), not a tuned-to-real-load number.
// Revisit once real registration volume exists (S12+).
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
    // that invoked this function (fail-open posture, matching internal.invoke_send_community_push()'s
    // own exception handling in supabase/04-community-push-trigger.sql).
    console.error(
      "send-community-push: missing one or more APNS_KEY_ID/APNS_TEAM_ID/APNS_PRIVATE_KEY/APNS_TOPIC secrets — skipping."
    );
    return new Response(
      JSON.stringify({ error: "APNs secrets not configured", sent: 0, skipped: true }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }
  if (apnsEnvRaw !== "sandbox" && apnsEnvRaw !== "production") {
    console.error(`send-community-push: invalid APNS_ENV "${apnsEnvRaw}" — falling back to sandbox.`);
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

  // Defense-in-depth: the pins_invoke_send_community_push trigger (04-community-push-trigger.sql)
  // already gates on source='crowd', lifespan='ephemeral', zone_id not null via its WHEN clause —
  // re-check here so this function is safe to invoke directly (e.g. a manual test call) too.
  if (pin.source !== "crowd" || pin.lifespan !== "ephemeral") {
    return new Response(
      JSON.stringify({ skipped: true, reason: "not an ephemeral crowd pin", sent: 0 }),
      { status: 200, headers: { "Content-Type": "application/json" } }
    );
  }
  if (!pin.zone_id) {
    return new Response(JSON.stringify({ skipped: true, reason: "zone_id is null", sent: 0 }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  // Service-role client bypasses RLS — required, since device_push_tokens deliberately has NO select
  // policy for any client role (spec §2.9).
  const { data: tokens, error: tokensError } = await supabase
    .from("device_push_tokens")
    .select("id, apns_token, environment")
    .eq("zone_id", pin.zone_id)
    .eq("environment", apnsEnv) // see the file header's "Environment selection" note
    .limit(MAX_TOKENS_PER_INVOCATION);

  if (tokensError) {
    console.error(`send-community-push: device_push_tokens query failed: ${tokensError.message}`);
    return new Response(JSON.stringify({ error: tokensError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const deviceTokens = (tokens ?? []) as DeviceTokenRow[];
  if (deviceTokens.length === 0) {
    console.log(
      `send-community-push: no ${apnsEnv} tokens for zone=${pin.zone_id} (pin=${pin.id}) — nothing to send.`
    );
    return new Response(JSON.stringify({ sent: 0, zone_id: pin.zone_id, pin_id: pin.id }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  let jwt: string;
  try {
    jwt = await getApnsJwt(apnsKeyId, apnsTeamId, apnsPrivateKey);
  } catch (err) {
    console.error(`send-community-push: failed to sign APNs provider JWT: ${String(err)}`);
    return new Response(JSON.stringify({ error: `JWT signing failed: ${String(err)}` }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const host = APNS_HOSTS[apnsEnv];
  // Silent (content-available) push, NO alert/sound/badge — see the file header's privacy note. The
  // client's local-notification decision (and any user-facing copy) happens entirely on-device. This
  // exact body/push-type/priority triple is byte-identical to what this function sent before the S3
  // _shared/apns.ts extraction — only WHERE the send loop lives changed, not what gets sent.
  const outcomes = await sendInChunks(deviceTokens, host, jwt, apnsTopic, {
    pushType: "background",
    priority: "5",
    body: {
      aps: { "content-available": 1 },
      pin_type: pin.pin_type,
      segment_id: pin.segment_id,
      pin_id: pin.id,
      zone_id: pin.zone_id,
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
        `send-community-push: failed to delete ${deadTokenIds.length} dead token row(s): ${deleteError.message}`
      );
    } else {
      console.log(`send-community-push: deleted ${deadTokenIds.length} dead token row(s) (410/BadDeviceToken).`);
    }
  }

  for (const o of failed) {
    if (!o.deleted) {
      console.error(
        `send-community-push: APNs send failed for token ${o.tokenId}: status=${o.status} error=${o.error}`
      );
    }
  }

  console.log(
    `send-community-push complete: pin=${pin.id} zone=${pin.zone_id} env=${apnsEnv} ` +
      `candidates=${deviceTokens.length} sent=${sent} failed=${failed.length} deadTokensRemoved=${deadTokenIds.length}`
  );

  return new Response(
    JSON.stringify({
      pin_id: pin.id,
      zone_id: pin.zone_id,
      environment: apnsEnv,
      candidates: deviceTokens.length,
      sent,
      failed: failed.length,
      deadTokensRemoved: deadTokenIds.length,
    }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
});
