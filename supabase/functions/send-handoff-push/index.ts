/**
 * send-handoff-push — Supabase Edge Function (Spot Pass, docs/specs/qr-spot-handoff.md Rev 2 section 7.1).
 *
 * SERVICE-ROLE ONLY. Invoked by Postgres (internal.handoff_push -> pg_net, Vault secret `service_role_key`, same
 * pattern as 08-regulars-push-trigger.sql) with `Authorization: Bearer <service-role-key>`; the bearer is verified
 * here in constant time. Deploy WITH the default JWT verification (do NOT pass --no-verify-jwt).
 *
 * Body: { "kind": "armed" | "departed" | "thanks" | "handoff_ended", "handoff_id": "<uuid>" }
 *
 *   armed          -> SEEKER   alert (app topic)      "A neighbor will be leaving in about N min."
 *   departed       -> SEEKER   alert (app topic)      "Your neighbor is pulling out now."
 *   thanks         -> DRIVER   alert to push token (app or clip topic, `target-content-id` for clips)
 *                              + ActivityKit push-to-END (liveactivity push type) with content-state {phase:"thanks"}
 *   handoff_ended  -> DRIVER   SILENT push (content-available) to the push token
 *                              + ActivityKit push-to-END with content-state {phase:"ended"}
 *
 * State gates (stateAllows) make stale/replayed dispatches harmless: `thanks` only for departed+got_spot, etc.
 * After driver-directed sends the claimer tokens are cleared at once (public.handoff_clear_tokens), so they live
 * only as long as the push needs them (spec 9 #13; the sweep is the backstop).
 *
 * Secrets (same as send-regular-push; nothing new to provision): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (injected),
 * APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_TOPIC (the APP bundle id), APNS_ENV. Optional:
 *   HANDOFF_EXTRA_TOPICS  extra allowed claimer bundle ids (comma separated)
 *   HANDOFF_APP_URL       clip experience URL used for target-content-id (default https://getwepark.com/p)
 *   HANDOFF_ENABLED       `false` to stop sending (kill switch)
 *
 * Claimer tokens carry no environment; they are sent to the function's own APNS_ENV (sandbox vs production),
 * same assumption the rest of the push stack makes.
 * LOGGING: kind, counts and APNs status classes only. Never a token, alias, name, id of a person, or location.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.119.2";
import { APNS_HOSTS, ApnsEnv, DeviceTokenRow, getApnsJwt, sendInChunks, sendOnePush } from "../_shared/apns.ts";
import { allowedTopics, bearer, envKillSwitch, json, isUuid, safeEqual } from "../_shared/handoff.ts";
import {
  driverThanksAlertBody,
  HandoffPushRow,
  isClipTopic,
  isPushKind,
  liveActivityEndBody,
  liveActivityTopic,
  seekerAlertBody,
  silentEndedBody,
  stateAllows,
} from "../_shared/handoff_push.ts";

const COLUMNS =
  "id, status, seeker_id, alias, seeker_display_name, leave_at, outcome, claimer_push_token, claimer_activity_token, claimer_topic";

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "server_error" }, 500);

  const presented = bearer(req.headers);
  if (!presented || !safeEqual(presented, serviceRoleKey)) return json({ error: "unauthorized" }, 401);

  if (envKillSwitch(Deno.env.get("HANDOFF_ENABLED"))) return json({ skipped: true, reason: "disabled" }, 200);

  const apnsKeyId = Deno.env.get("APNS_KEY_ID");
  const apnsTeamId = Deno.env.get("APNS_TEAM_ID");
  const apnsPrivateKey = Deno.env.get("APNS_PRIVATE_KEY");
  const apnsTopic = Deno.env.get("APNS_TOPIC");
  if (!apnsKeyId || !apnsTeamId || !apnsPrivateKey || !apnsTopic) {
    console.error("send-handoff-push: APNs secrets not configured — skipping.");
    return json({ skipped: true, reason: "apns_not_configured", sent: 0 }, 200); // fail open, like its siblings
  }
  const apnsEnv: ApnsEnv = (Deno.env.get("APNS_ENV") ?? "sandbox").trim().toLowerCase() === "production"
    ? "production"
    : "sandbox";

  let payload: { kind?: unknown; handoff_id?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid_request" }, 400);
  }
  if (!isPushKind(payload.kind) || !isUuid(payload.handoff_id)) return json({ error: "invalid_request" }, 400);
  const kind = payload.kind;

  const svc = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const { data, error } = await svc.from("spot_handoffs").select(COLUMNS).eq("id", payload.handoff_id).maybeSingle();
  if (error) {
    console.error(`send-handoff-push: row lookup failed (${kind}).`);
    return json({ error: "server_error" }, 500);
  }
  const row = data as HandoffPushRow | null;
  if (!row) return json({ skipped: true, reason: "gone", sent: 0 }, 200);
  if (!stateAllows(kind, row)) return json({ skipped: true, reason: "state_mismatch", sent: 0 }, 200);

  let jwt: string;
  try {
    jwt = await getApnsJwt(apnsKeyId, apnsTeamId, apnsPrivateKey);
  } catch {
    console.error("send-handoff-push: failed to sign APNs provider JWT.");
    return json({ error: "server_error" }, 500);
  }
  const host = APNS_HOSTS[apnsEnv];
  const nowMs = Date.now();
  const nowSec = Math.floor(nowMs / 1000);

  // ---- SEEKER-directed (armed / departed): alert to the seeker's registered device tokens, app topic ------------
  if (kind === "armed" || kind === "departed") {
    const { data: tokens, error: tErr } = await svc
      .from("device_push_tokens")
      .select("id, apns_token, environment")
      .eq("user_id", row.seeker_id)
      .eq("environment", apnsEnv)
      .limit(20);
    if (tErr) {
      console.error(`send-handoff-push: token lookup failed (${kind}).`);
      return json({ error: "server_error" }, 500);
    }
    const deviceTokens = (tokens ?? []) as DeviceTokenRow[];
    if (deviceTokens.length === 0) return json({ kind, sent: 0, candidates: 0 }, 200);
    const outcomes = await sendInChunks(deviceTokens, host, jwt, apnsTopic, {
      pushType: "alert",
      priority: "10",
      body: seekerAlertBody(kind, row, nowMs),
    });
    const dead = outcomes.filter((o) => o.deleted).map((o) => o.tokenId);
    if (dead.length > 0) await svc.from("device_push_tokens").delete().in("id", dead);
    const sent = outcomes.filter((o) => o.ok).length;
    console.log(`send-handoff-push: kind=${kind} env=${apnsEnv} candidates=${deviceTokens.length} sent=${sent}`);
    return json({ kind, candidates: deviceTokens.length, sent, deadTokensRemoved: dead.length }, 200);
  }

  // ---- DRIVER-directed (thanks / handoff_ended): tokens live on the row, then are cleared --------------------------
  const allowed = allowedTopics(apnsTopic, Deno.env.get("HANDOFF_EXTRA_TOPICS"));
  const bundle = row.claimer_topic && allowed.includes(row.claimer_topic) ? row.claimer_topic : apnsTopic;
  const clipUrl = Deno.env.get("HANDOFF_APP_URL") ?? "https://getwepark.com/p";
  let sent = 0;
  let attempted = 0;

  if (row.claimer_push_token) {
    attempted++;
    const spec = kind === "thanks"
      ? {
        pushType: "alert" as const,
        priority: "10" as const,
        body: driverThanksAlertBody(row, isClipTopic(bundle, apnsTopic), clipUrl),
      }
      : { pushType: "background" as const, priority: "5" as const, body: silentEndedBody(row) };
    const o = await sendOnePush(
      { id: row.id, apns_token: row.claimer_push_token, environment: apnsEnv },
      host,
      jwt,
      bundle,
      spec,
    );
    if (o.ok) sent++;
  }
  if (row.claimer_activity_token) {
    attempted++;
    const o = await sendOnePush(
      { id: row.id, apns_token: row.claimer_activity_token, environment: apnsEnv },
      host,
      jwt,
      liveActivityTopic(bundle),
      { pushType: "liveactivity", priority: "10", body: liveActivityEndBody(kind, row, nowSec) },
    );
    if (o.ok) sent++;
  }

  // Tokens leave the row as soon as the push has used them (even if APNs said no: a dead token is useless).
  const { error: clearErr } = await svc.rpc("handoff_clear_tokens", { p_id: row.id });
  if (clearErr) console.error(`send-handoff-push: token clear failed (${kind}); the minute sweep is the backstop.`);

  console.log(`send-handoff-push: kind=${kind} env=${apnsEnv} attempted=${attempted} sent=${sent}`);
  return json({ kind, attempted, sent }, 200);
});
