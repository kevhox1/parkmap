/**
 * _shared/handoff.ts — pure helpers for the Spot Pass Edge Functions (docs/specs/qr-spot-handoff.md Rev 2, §8-9).
 * No network, no esm.sh imports: everything here is unit-testable offline (see handoff_test.ts).
 *
 * PRIVACY RULES THIS MODULE ENFORCES FOR EVERY handoff-* FUNCTION
 *  - Tokens, claimer secrets and IP addresses are never logged and never echoed. Nothing in this file logs.
 *  - The raw client IP never leaves the function: it is HMAC'd with a server-side salt and only the digest is
 *    handed to the database, solely so rate limits can key on it (spec 9 #8).
 *  - Bad / expired / used / self-scanned / wrong-secret all collapse to ONE response per endpoint (spec 8).
 */

// ---------------------------------------------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------------------------------------------

/** Pass token / claimer secret: 128-bit random, base64url, 22 chars (unpadded). */
const B64URL_22 = /^[A-Za-z0-9_-]{22}$/;
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const APNS_TOKEN_RE = /^[0-9a-fA-F]{32,200}$/;
const ACTIVITY_TOKEN_RE = /^[0-9a-fA-F]{32,1000}$/;

export const DEPART_SOURCES = [
  "manual",
  "live_activity",
  "notification",
  "auto",
  "start_driving",
  "shortcut",
] as const;
export type DepartSource = (typeof DEPART_SOURCES)[number];

export const REPORT_REASONS = ["harassment", "spam", "unsafe", "other"] as const;

/** Maximum request body we will read. Real payloads are well under 1 KB (activity tokens are the largest). */
export const MAX_BODY_BYTES = 4096;

export function isToken(v: unknown): v is string {
  return typeof v === "string" && B64URL_22.test(v);
}
export function isSecret(v: unknown): v is string {
  return typeof v === "string" && B64URL_22.test(v);
}
export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}
export function isDepartSource(v: unknown): v is DepartSource {
  return typeof v === "string" && (DEPART_SOURCES as readonly string[]).includes(v);
}
export function isReportReason(v: unknown): v is string {
  return typeof v === "string" && (REPORT_REASONS as readonly string[]).includes(v);
}

export interface ClaimInput {
  token: string;
  leaveAt: string; // normalized ISO-8601 (UTC)
  pushToken: string | null;
  activityToken: string | null;
  topic: string | null;
}

/** Validates a handoff-claim body. Returns the normalized input or a short machine reason (never echoes input). */
export function parseClaimBody(
  body: unknown,
  allowedTopics: string[],
  defaultTopic: string | null,
): { ok: true; value: ClaimInput } | { ok: false; reason: string } {
  if (!body || typeof body !== "object") return { ok: false, reason: "invalid_request" };
  const b = body as Record<string, unknown>;
  if (!isToken(b.token)) return { ok: false, reason: "bad_token_format" }; // treated as "unavailable" by the caller
  if (typeof b.leave_at !== "string") return { ok: false, reason: "invalid_leave_at" };
  const t = Date.parse(b.leave_at);
  if (!Number.isFinite(t)) return { ok: false, reason: "invalid_leave_at" };
  const pushToken = b.push_token ?? null;
  const activityToken = b.activity_token ?? null;
  if (pushToken !== null && !(typeof pushToken === "string" && APNS_TOKEN_RE.test(pushToken))) {
    return { ok: false, reason: "invalid_request" };
  }
  if (activityToken !== null && !(typeof activityToken === "string" && ACTIVITY_TOKEN_RE.test(activityToken))) {
    return { ok: false, reason: "invalid_request" };
  }
  let topic: string | null = null;
  if (pushToken !== null || activityToken !== null) {
    topic = typeof b.topic === "string" ? b.topic : defaultTopic;
    if (topic === null || !allowedTopics.includes(topic)) return { ok: false, reason: "invalid_request" };
  } else if (b.topic !== undefined && b.topic !== null && typeof b.topic !== "string") {
    return { ok: false, reason: "invalid_request" };
  }
  return {
    ok: true,
    value: { token: b.token, leaveAt: new Date(t).toISOString(), pushToken, activityToken, topic },
  };
}

/** Allowed bundle-id topics for claimer push tokens: the app and its clip (+ explicit extras). */
export function allowedTopics(appTopic: string | null | undefined, extra: string | null | undefined): string[] {
  const out: string[] = [];
  if (appTopic) {
    out.push(appTopic, `${appTopic}.Clip`);
  }
  for (const t of (extra ?? "").split(",")) {
    const s = t.trim();
    if (s && !out.includes(s)) out.push(s);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// Request plumbing
// ---------------------------------------------------------------------------------------------------------------

/** Kill switch: the env var can force the feature OFF (HANDOFF_ENABLED=false|0|off|no). The database flag
 * (public.handoff_config) is the source of truth for turning it ON; this is the belt for an emergency stop that
 * does not need SQL. Unset = defer to the database. */
export function envKillSwitch(v: string | null | undefined): boolean {
  return ["false", "0", "off", "no"].includes((v ?? "").trim().toLowerCase());
}

/** Origins that get CORS headers (browser fallback page). Native clients send no Origin and need none. */
export function corsHeaders(origin: string | null, allowed: string[]): Record<string, string> {
  const base: Record<string, string> = { Vary: "Origin" };
  if (origin && allowed.includes(origin)) {
    base["Access-Control-Allow-Origin"] = origin;
    base["Access-Control-Allow-Methods"] = "POST, OPTIONS";
    base["Access-Control-Allow-Headers"] = "authorization, apikey, content-type, x-client-info";
    base["Access-Control-Max-Age"] = "600";
  }
  return base;
}

export function allowedOrigins(env: string | null | undefined): string[] {
  const list = (env ?? "https://getwepark.com").split(",").map((s) => s.trim()).filter(Boolean);
  return list;
}

/**
 * Client IP for rate-limit keys. NEVER the first X-Forwarded-For hop: that one is whatever the client sent.
 * Source for the order below (cited, not guaranteed by Supabase docs; hence the post-deploy forged-XFF test in
 * README-handoff.md): Supabase Edge Functions sit behind Cloudflare. Cloudflare OVERWRITES `cf-connecting-ip` with the
 * real peer, and APPENDS the real peer to any client-supplied X-Forwarded-For (community report: "the real IP is
 * concatenated with the spoofed one as a proxy", https://github.com/orgs/supabase/discussions/34647 — Supabase has
 * not published a guarantee). So: 1) cf-connecting-ip, 2) the LAST x-forwarded-for hop (appended by the trusted
 * proxy, not the client), 3) "unknown" (one shared bucket: fails closed for the unattributable, per-token limits
 * still apply). Per-token limits stay primary; a shared CGNAT IP only shares the 30/h peek budget. Never logged.
 */
export function clientIp(headers: Headers): string {
  const cf = headers.get("cf-connecting-ip")?.trim();
  if (cf) return cf;
  const xff = headers.get("x-forwarded-for");
  if (xff) {
    const hops = xff.split(",").map((h) => h.trim()).filter(Boolean);
    if (hops.length) return hops[hops.length - 1];
  }
  return "unknown";
}

/** HMAC-SHA256(salt, ip) -> first 32 hex chars. Only this value is stored (rate-limit key). */
export async function ipHash(ip: string, salt: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(salt),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(ip)));
  return Array.from(sig.slice(0, 16)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Reads and parses a size-capped JSON body. Returns null on any problem. The cap is enforced WHILE STREAMING so a
 * chunked body without Content-Length cannot be buffered whole. */
export async function readJsonBody(req: Request): Promise<unknown | null> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) return null;
  try {
    if (!req.body) return null;
    const reader = req.body.getReader();
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_BODY_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
    const buf = new Uint8Array(total);
    let off = 0;
    for (const c of chunks) {
      buf.set(c, off);
      off += c.byteLength;
    }
    return JSON.parse(new TextDecoder().decode(buf));
  } catch {
    return null;
  }
}

/** The single "this didn't work" body per endpoint family. */
export const UNAVAILABLE = { status: "unavailable" } as const;
export const NOT_OK = { ok: false } as const;

export function json(body: unknown, status: number, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...extra },
  });
}

/** Maps an RPC result carrying a control flag to an HTTP response. `deniedBody` is what a legitimate client sees
 * for rate limiting (same shape as a plain failure; the 429 status is the only difference). */
export function controlFlagResponse(
  rpc: Record<string, unknown> | null,
  deniedBody: Record<string, unknown>,
  extra: Record<string, string>,
): Response | null {
  if (!rpc) return null;
  if (rpc.disabled === true) return json({ error: "disabled" }, 503, extra);
  if (rpc.rate_limited === true) return json(deniedBody, 429, { "Retry-After": "600", ...extra });
  return null;
}

/** Bearer token from an Authorization header, or null. */
export function bearer(headers: Headers): string | null {
  const h = headers.get("authorization");
  if (!h) return null;
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return m ? m[1].trim() : null;
}

/** Constant-time string comparison (for the service-role bearer check on send-handoff-push). */
export function safeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  const n = Math.max(ea.length, eb.length);
  for (let i = 0; i < n; i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}
