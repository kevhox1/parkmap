/**
 * handoff-peek — Spot Pass Edge Function (docs/specs/qr-spot-handoff.md Rev 2 section 8). Anonymous-callable:
 * deploy with `supabase functions deploy handoff-peek --no-verify-jwt`. Gate = the pass token, checked in the DB.
 * No logging of tokens, secrets or IPs. See _shared/handoff.ts and _shared/handoff_runtime.ts.
 *
 * POST {token} -> {status:"open", alias, glyph, display_name|null} | {status:"unavailable"}
 * Read-only. Byte-identical answer for bad / expired / used / suspended tokens (no oracle). 30/hour/IP.
 */
import { isToken, json, UNAVAILABLE } from "../_shared/handoff.ts";
import { callRpc, serveEndpoint } from "../_shared/handoff_runtime.ts";

serveEndpoint({
  name: "handoff-peek",
  deniedBody: UNAVAILABLE,
  handle: async (ctx) => {
    if (!isToken(ctx.body.token)) return json(UNAVAILABLE, 200, ctx.cors);
    const r = await callRpc(ctx, "handoff_peek", { p_token: ctx.body.token, p_ip_hash: ctx.ipHash }, UNAVAILABLE);
    if ("response" in r) return r.response;
    return json(
      r.rpc.status === "open"
        ? { status: "open", alias: r.rpc.alias, glyph: r.rpc.glyph, display_name: r.rpc.display_name ?? null }
        : UNAVAILABLE,
      200,
      ctx.cors,
    );
  },
});
