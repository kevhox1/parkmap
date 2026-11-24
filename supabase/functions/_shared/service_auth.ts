/**
 * Service-role bearer gate for trigger-invoked Edge Functions (send-community-push, send-regular-push).
 *
 * WHY: the gateway's `verify_jwt` accepts ANY valid project JWT, including the PUBLIC anon key embedded in the
 * app, so it is not authentication for functions that act on a caller-supplied body. The only legitimate callers
 * are Postgres (pg_net triggers / sweep) which send `Authorization: Bearer <Vault service_role_key>`. This checks
 * that bearer, in constant time, against the function's own SUPABASE_SERVICE_ROLE_KEY secret.
 *
 * Same comparison send-handoff-push uses (bearer + safeEqual from handoff.ts): an opaque string compare, so it is
 * agnostic to key style (legacy JWT service_role key or new `sb_secret_*`) AS LONG AS the Vault `service_role_key`
 * holds the exact same value the runtime injects as SUPABASE_SERVICE_ROLE_KEY. Keep them in sync on key rotation.
 *
 * Call AFTER confirming the server secret exists and BEFORE reading/parsing the body.
 */
import { bearer, safeEqual } from "./handoff.ts";

/** Uniform 401 for every failure mode (missing / malformed / wrong bearer): no oracle. */
export function unauthorizedResponse(): Response {
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "Content-Type": "application/json" },
  });
}

/** True iff the request carries `Authorization: Bearer <serviceRoleKey>` (constant-time compare). */
export function isServiceRoleRequest(headers: Headers, serviceRoleKey: string): boolean {
  const presented = bearer(headers);
  return !!presented && !!serviceRoleKey && safeEqual(presented, serviceRoleKey);
}

/** Returns a 401 Response when the caller is not the service role, else null. */
export function requireServiceRole(req: Request, serviceRoleKey: string): Response | null {
  return isServiceRoleRequest(req.headers, serviceRoleKey) ? null : unauthorizedResponse();
}
