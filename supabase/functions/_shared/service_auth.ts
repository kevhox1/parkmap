/**
 * Service-role gate for trigger-invoked Edge Functions (send-community-push, send-regular-push, send-handoff-push).
 *
 * !!! SECURITY INVARIANT: these functions MUST stay deployed WITH the gateway's JWT verification (the default,
 * !!! `verify_jwt = true`). NEVER deploy them with `--no-verify-jwt`. The role-claim check below does NOT verify
 * !!! the token signature; it trusts that the Supabase gateway already did. Without verify_jwt anyone could forge
 * !!! an unsigned `{"role":"service_role"}` token and pass.
 *
 * WHY: verify_jwt accepts ANY validly signed project JWT, including the PUBLIC anon key shipped in the app, so on
 * its own it is not authentication for functions that act on a caller-supplied body. The legitimate callers are
 * Postgres (pg_net triggers / sweeps) sending `Authorization: Bearer <Vault service_role_key>`.
 *
 * DESIGN (replaces an exact compare against SUPABASE_SERVICE_ROLE_KEY): production showed the Vault
 * `service_role_key` is a valid service-role JWT but NOT byte-equal to the runtime-injected
 * SUPABASE_SERVICE_ROLE_KEY (new-style key injection / key rotation). So a caller is accepted if EITHER
 *   1. the bearer is a JWT whose payload has `role === "service_role"` (anon => role "anon" => rejected), plus sane
 *      `ref` (must equal the project ref from SUPABASE_URL, when both are present) and `iss` (must start with
 *      "supabase", when present), or
 *   2. the bearer is an exact constant-time match to SUPABASE_SERVICE_ROLE_KEY (covers opaque `sb_secret_*` keys).
 * Everything else gets the uniform `401 {"error":"unauthorized"}`. Call BEFORE parsing the body / touching the DB / APNs.
 */
import { bearer, safeEqual } from "./handoff.ts";

/** Uniform 401 for every failure mode (missing / malformed / wrong bearer): no oracle. */
export function unauthorizedResponse(): Response {
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "Content-Type": "application/json" },
  });
}

/** Decode a JWT payload WITHOUT verifying the signature (the gateway did). Null if not a 3-part JWT with a JSON-object payload. */
export function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[1]) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
    const bin = atob(padded);
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    const obj = JSON.parse(new TextDecoder().decode(bytes));
    return obj && typeof obj === "object" && !Array.isArray(obj) ? (obj as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/** Project ref = first label of the SUPABASE_URL host (https://<ref>.supabase.co), or null if unparseable. */
export function projectRefFromUrl(supabaseUrl: string | undefined | null): string | null {
  if (!supabaseUrl) return null;
  try {
    const label = new URL(supabaseUrl).hostname.split(".")[0];
    return label || null;
  } catch {
    return null;
  }
}

/** True iff the JWT-shaped token claims role service_role (+ sane ref / iss). Signature is NOT checked here. */
export function hasServiceRoleClaim(token: string, supabaseUrl?: string | null): boolean {
  const p = decodeJwtPayload(token);
  if (!p || p.role !== "service_role") return false;
  if (p.iss !== undefined && !(typeof p.iss === "string" && p.iss.startsWith("supabase"))) return false;
  if (p.ref !== undefined) {
    const want = projectRefFromUrl(supabaseUrl);
    if (typeof p.ref !== "string" || (want !== null && p.ref !== want)) return false;
  }
  return true;
}

/** True iff the request is from the service role (see DESIGN above). */
export function isServiceRoleRequest(
  headers: Headers,
  serviceRoleKey: string,
  supabaseUrl?: string | null,
): boolean {
  const presented = bearer(headers);
  if (!presented) return false;
  if (serviceRoleKey && safeEqual(presented, serviceRoleKey)) return true;
  return hasServiceRoleClaim(presented, supabaseUrl);
}

/** Returns a 401 Response when the caller is not the service role, else null. */
export function requireServiceRole(
  req: Request,
  serviceRoleKey: string,
  supabaseUrl?: string | null,
): Response | null {
  return isServiceRoleRequest(req.headers, serviceRoleKey, supabaseUrl) ? null : unauthorizedResponse();
}

/**
 * Startup self-check (call once at module load). verify_jwt cannot be introspected from inside the function, so this
 * only logs the invariant and flags an obviously wrong environment (a JWT-style SUPABASE_SERVICE_ROLE_KEY that is not
 * role service_role). Logs only; never throws.
 */
export function logAuthStartup(fn: string, serviceRoleKey: string | undefined): void {
  console.log(`${fn}: service auth = role-claim JWT (requires gateway verify_jwt; never deploy --no-verify-jwt) OR exact env key`);
  if (serviceRoleKey) {
    const p = decodeJwtPayload(serviceRoleKey);
    if (p && p.role !== "service_role") {
      console.warn(`${fn}: WARNING SUPABASE_SERVICE_ROLE_KEY is a JWT but role is not service_role`);
    }
  }
}
