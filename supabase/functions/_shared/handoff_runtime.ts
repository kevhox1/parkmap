/**
 * _shared/handoff_runtime.ts — the Supabase-touching half of the Spot Pass function plumbing (kept separate from
 * handoff.ts so the pure helpers stay testable offline). One factory builds every anonymous-callable endpoint so
 * the five public functions share exactly the same CORS / kill-switch / rate-limit / error behavior.
 *
 * Auth model (all five public endpoints + handoff-report): ANONYMOUS-CALLABLE. Deploy with `--no-verify-jwt`
 * (the web fallback page and the clip carry no session; the real gate is the 128-bit token / claimer secret
 * checked inside the database). If the caller DOES send a user access token (`Authorization: Bearer <jwt>`), we
 * resolve the user id from it — used only by handoff-claim, to attribute karma to the claimer's anonymous
 * identity. A bearer that is just the public anon key resolves to no user and is ignored.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  allowedOrigins,
  bearer,
  clientIp,
  controlFlagResponse,
  corsHeaders,
  envKillSwitch,
  ipHash,
  json,
  readJsonBody,
} from "./handoff.ts";

// deno-lint-ignore no-explicit-any
export type Svc = any; // untyped service-role client (no generated DB types in this repo)

export interface EndpointContext {
  svc: Svc;
  body: Record<string, unknown>;
  ipHash: string;
  /** Verified user id from a user access token, else null. Never trusted from the body. */
  userId: string | null;
  cors: Record<string, string>;
}

interface EndpointSpec {
  name: string;
  /** Body returned to the client when rate limited (HTTP 429) and when the body itself is unusable. */
  deniedBody: Record<string, unknown>;
  /** Resolve the claimer's user id from the bearer (claim only). */
  resolveUser?: boolean;
  handle: (ctx: EndpointContext) => Promise<Response>;
}

export function serveEndpoint(spec: EndpointSpec): void {
  Deno.serve(async (req: Request): Promise<Response> => {
    const cors = corsHeaders(req.headers.get("origin"), allowedOrigins(Deno.env.get("HANDOFF_ALLOWED_ORIGINS")));

    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405, cors);

    // Emergency stop that needs no SQL (the DB flag public.handoff_config is the normal switch).
    if (envKillSwitch(Deno.env.get("HANDOFF_ENABLED"))) return json({ error: "disabled" }, 503, cors);

    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) return json({ error: "server_error" }, 500, cors);

    const raw = await readJsonBody(req);
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return json({ error: "invalid_request" }, 400, cors);

    const svc = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
    const salt = Deno.env.get("HANDOFF_IP_SALT") || key; // service key is always present; a dedicated salt is optional
    const hashed = await ipHash(clientIp(req.headers), salt);

    let userId: string | null = null;
    if (spec.resolveUser) {
      const jwt = bearer(req.headers);
      if (jwt) {
        try {
          const { data } = await svc.auth.getUser(jwt);
          userId = data?.user?.id ?? null;
        } catch {
          userId = null; // anon key / garbage / expired => no karma identity, claim still works
        }
      }
    }

    try {
      return await spec.handle({ svc, body: raw as Record<string, unknown>, ipHash: hashed, userId, cors });
    } catch {
      // Deliberately no logging of the request (tokens/secrets/IP live in it). Generic failure only.
      return json({ error: "server_error" }, 500, cors);
    }
  });
}

/** Calls a service RPC and maps disabled/rate-limit flags. Returns {response} to short-circuit or {rpc} to continue. */
export async function callRpc(
  ctx: EndpointContext,
  fn: string,
  args: Record<string, unknown>,
  deniedBody: Record<string, unknown>,
): Promise<{ response: Response } | { rpc: Record<string, unknown> }> {
  const { data, error } = await ctx.svc.rpc(fn, args);
  if (error) return { response: json({ error: "server_error" }, 500, ctx.cors) };
  const rpc = (data ?? {}) as Record<string, unknown>;
  const flagged = controlFlagResponse(rpc, deniedBody, ctx.cors);
  if (flagged) return { response: flagged };
  return { rpc };
}
