/**
 * handoff-report — Spot Pass Edge Function. ADDITIVE to the section 8 contract (section 9 #9 requires abuse
 * reporting on the web page / clip but the contract listed no endpoint). Anonymous-callable:
 * deploy with `supabase functions deploy handoff-report --no-verify-jwt`.
 *
 * POST {token, reason}                      (pass not yet claimed)     -> {ok:boolean}
 * POST {id, claimer_secret, reason}         (pass armed by the caller) -> {ok:boolean}
 * reason in harassment|spam|unsafe|other. A report ends the pass immediately; 3 reports against one user in 30
 * days suspend that user from creating (or claiming) passes. 10/hour/IP.
 */
import { isReportReason, isSecret, isToken, isUuid, json, NOT_OK } from "../_shared/handoff.ts";
import { callRpc, serveEndpoint } from "../_shared/handoff_runtime.ts";

serveEndpoint({
  name: "handoff-report",
  deniedBody: NOT_OK,
  handle: async (ctx) => {
    const { token, id, claimer_secret: secret, reason } = ctx.body;
    if (!isReportReason(reason)) return json({ error: "invalid_reason" }, 400, ctx.cors);
    let args: Record<string, unknown>;
    if (isToken(token)) {
      args = { p_token: token, p_id: null, p_secret: null };
    } else if (isUuid(id) && isSecret(secret)) {
      args = { p_token: null, p_id: id, p_secret: secret };
    } else {
      return json(NOT_OK, 200, ctx.cors);
    }
    const r = await callRpc(ctx, "handoff_report", { ...args, p_reason: reason, p_ip_hash: ctx.ipHash }, NOT_OK);
    if ("response" in r) return r.response;
    return json({ ok: r.rpc.ok === true }, 200, ctx.cors);
  },
});
