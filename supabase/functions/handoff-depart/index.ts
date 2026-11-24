/**
 * handoff-depart — Spot Pass Edge Function (docs/specs/qr-spot-handoff.md Rev 2 section 8). Anonymous-callable:
 * deploy with `supabase functions deploy handoff-depart --no-verify-jwt`. Gate = the claimer secret, checked in the DB.
 * No logging of tokens, secrets or IPs. See _shared/handoff.ts and _shared/handoff_runtime.ts.
 *
 * POST {id, claimer_secret, source} -> {ok:boolean}
 * source in manual|live_activity|notification|auto|start_driving|shortcut. The QR token alone can NOT depart.
 * Wrong id / wrong secret / expired / already terminal all return the same {ok:false}. 20/hour/pass.
 * A repeat call after success returns {ok:false} (the secret is nulled at the terminal transition): clients should
 * treat ok:false on a RETRY as "may already have been sent".
 */
import { isDepartSource, isSecret, isUuid, json, NOT_OK } from "../_shared/handoff.ts";
import { callRpc, serveEndpoint } from "../_shared/handoff_runtime.ts";

serveEndpoint({
  name: "handoff-depart",
  deniedBody: NOT_OK,
  handle: async (ctx) => {
    const { id, claimer_secret: secret, source } = ctx.body;
    if (!isDepartSource(source)) return json({ error: "invalid_source" }, 400, ctx.cors);
    if (!isUuid(id) || !isSecret(secret)) return json(NOT_OK, 200, ctx.cors);
    const r = await callRpc(ctx, "handoff_depart", { p_id: id, p_secret: secret, p_source: source }, NOT_OK);
    if ("response" in r) return r.response;
    return json({ ok: r.rpc.ok === true }, 200, ctx.cors);
  },
});
