/**
 * handoff-cancel — Spot Pass Edge Function (docs/specs/qr-spot-handoff.md Rev 2 section 8). Anonymous-callable:
 * deploy with `supabase functions deploy handoff-cancel --no-verify-jwt`. Gate = the claimer secret, checked in the DB.
 * No logging of tokens, secrets or IPs. See _shared/handoff.ts and _shared/handoff_runtime.ts.
 *
 * POST {id, claimer_secret} -> {ok:boolean}
 * Driver "Not leaving": SILENT to the seeker (no push, seeker-visible status unchanged). 20/hour/pass.
 */
import { isSecret, isUuid, json, NOT_OK } from "../_shared/handoff.ts";
import { callRpc, serveEndpoint } from "../_shared/handoff_runtime.ts";

serveEndpoint({
  name: "handoff-cancel",
  deniedBody: NOT_OK,
  handle: async (ctx) => {
    const { id, claimer_secret: secret } = ctx.body;
    if (!isUuid(id) || !isSecret(secret)) return json(NOT_OK, 200, ctx.cors);
    const r = await callRpc(ctx, "handoff_cancel_claim", { p_id: id, p_secret: secret }, NOT_OK);
    if ("response" in r) return r.response;
    return json({ ok: r.rpc.ok === true }, 200, ctx.cors);
  },
});
