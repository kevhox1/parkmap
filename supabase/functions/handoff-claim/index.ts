/**
 * handoff-claim — Spot Pass Edge Function (docs/specs/qr-spot-handoff.md Rev 2 section 8). Anonymous-callable:
 * deploy with `supabase functions deploy handoff-claim --no-verify-jwt`. Gate = the pass token, checked in the DB.
 * No logging of tokens, secrets or IPs. See _shared/handoff.ts and _shared/handoff_runtime.ts.
 *
 * POST {token, leave_at, push_token?, activity_token?, topic?}
 *   -> {status:"armed", leave_at, expires_at, claimer_secret} | {status:"unavailable"}
 * Atomic one-time arm (row lock in handoff_claim). leave_at is rounded to 5 min server-side, capped at 240 min
 * (above that: HTTP 400 {"error":"invalid_leave_at"}, decided before the token is looked at).
 * `Authorization: Bearer <user access token>` (the clip's/app's anonymous session) is OPTIONAL: when present the
 * verified user id is recorded as the claimer so karma can be awarded. Without it the pass still arms.
 * `topic` = bundle id the push_token belongs to (app or clip); the Live Activity topic is derived from it.
 */
import { allowedTopics, json, parseClaimBody, UNAVAILABLE } from "../_shared/handoff.ts";
import { callRpc, serveEndpoint } from "../_shared/handoff_runtime.ts";

serveEndpoint({
  name: "handoff-claim",
  deniedBody: UNAVAILABLE,
  resolveUser: true,
  handle: async (ctx) => {
    const appTopic = Deno.env.get("APNS_TOPIC");
    const parsed = parseClaimBody(
      ctx.body,
      allowedTopics(appTopic, Deno.env.get("HANDOFF_EXTRA_TOPICS")),
      appTopic ?? null,
    );
    if (!parsed.ok) {
      if (parsed.reason === "bad_token_format") return json(UNAVAILABLE, 200, ctx.cors);
      return json({ error: parsed.reason }, 400, ctx.cors);
    }
    const v = parsed.value;
    const r = await callRpc(ctx, "handoff_claim", {
      p_token: v.token,
      p_leave_at: v.leaveAt,
      p_push_token: v.pushToken,
      p_activity_token: v.activityToken,
      p_topic: v.topic,
      p_claimer: ctx.userId,
      p_ip_hash: ctx.ipHash,
    }, UNAVAILABLE);
    if ("response" in r) return r.response;
    if (r.rpc.invalid_leave_at === true) return json({ error: "invalid_leave_at" }, 400, ctx.cors);
    if (r.rpc.status === "armed") {
      return json({
        status: "armed",
        leave_at: r.rpc.leave_at,
        expires_at: r.rpc.expires_at,
        claimer_secret: r.rpc.claimer_secret,
      }, 200, ctx.cors);
    }
    return json(UNAVAILABLE, 200, ctx.cors);
  },
});
