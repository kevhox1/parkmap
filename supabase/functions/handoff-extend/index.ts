/**
 * handoff-extend — Spot Pass Edge Function (docs/specs/qr-spot-handoff.md Rev 2 section 8). Anonymous-callable:
 * deploy with `supabase functions deploy handoff-extend --no-verify-jwt`. Gate = the claimer secret, checked in the DB.
 * No logging of tokens, secrets or IPs. See _shared/handoff.ts and _shared/handoff_runtime.ts.
 *
 * POST {id, claimer_secret} -> {ok:true, leave_at, expires_at} | {ok:false}
 * "5 more min": +5 min on leave_at, max 3 extensions, never past 240 min from the claim. 20/hour/pass.
 */
import { isSecret, isUuid, json, NOT_OK } from "../_shared/handoff.ts";
import { callRpc, serveEndpoint } from "../_shared/handoff_runtime.ts";

serveEndpoint({
  name: "handoff-extend",
  deniedBody: NOT_OK,
  handle: async (ctx) => {
    const { id, claimer_secret: secret } = ctx.body;
    if (!isUuid(id) || !isSecret(secret)) return json(NOT_OK, 200, ctx.cors);
    const r = await callRpc(ctx, "handoff_extend", { p_id: id, p_secret: secret }, NOT_OK);
    if ("response" in r) return r.response;
    if (r.rpc.ok === true) {
      return json({ ok: true, leave_at: r.rpc.leave_at, expires_at: r.rpc.expires_at }, 200, ctx.cors);
    }
    return json(NOT_OK, 200, ctx.cors);
  },
});
