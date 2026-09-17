/**
 * _shared/apns.ts — APNs signing + delivery primitives shared by every WePark push Edge Function.
 *
 * Extracted from send-community-push/index.ts (Community 2.0 Phase 4b, S11) during Regulars S3
 * (docs/regulars-roadmap.md), per docs/regulars-network-spec.md §2.9's own recommendation: "recommend
 * factoring the raw APNs HTTP/2 send + dead-token-cleanup logic into a shared
 * supabase/functions/_shared/apns.ts module so both functions call the same hardened code instead of
 * forking it, closing the door on the two functions silently drifting apart over time."
 *
 * BEHAVIOR-PRESERVING EXTRACTION ONLY. Every function below is the same logic that lived inline in
 * send-community-push/index.ts before this change — base64url helpers, PEM parsing, ES256 JWT
 * signing/caching, and the raw fetch-and-classify-response send loop are all copied verbatim (control
 * flow, variable names, dead-token classification rule, error handling) with exactly one deliberate
 * generalization: `sendOnePush`/`sendInChunks` used to build the APNs request body inline from a
 * `PinRecord` (community push's own silent-payload shape hardcoded into the shared function); they now
 * take an explicit `ApnsRequestSpec { pushType, priority, body }` supplied by the CALLER instead, so
 * this file has no opinion about payload shape (silent vs visible, community vs Regulars). This is the
 * only path that changed shape — the actual bytes sent over the wire for send-community-push are
 * unaffected, because its own index.ts now constructs the exact same body/headers it always did and
 * passes them in explicitly (see that file's post-refactor diff and its own header comment).
 *
 * ⚠️ send-community-push/index.ts is a LIVE, DEPLOYED function. This extraction changes its SOURCE on
 * `main` but does NOT change what's running in production until send-community-push is re-deployed
 * (`supabase functions deploy send-community-push`) — that redeploy is Kevin's ceremony, not part of
 * this PR (files only, no deploy). Until then, production keeps running whatever copy is already
 * deployed, byte-identical to before this PR. See the PR description for the recommended combined
 * deploy step (redeploy send-community-push + deploy send-regular-push together, since both now depend
 * on this file existing in the deployed function bundle).
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface DeviceTokenRow {
  id: string;
  apns_token: string;
  environment: "sandbox" | "production";
}

export type ApnsEnv = "sandbox" | "production";

export interface PushOutcome {
  tokenId: string;
  status: number | null;
  ok: boolean;
  deleted: boolean;
  error?: string;
}

/**
 * Everything about an outbound APNs request that varies by CALLER (payload shape, background vs
 * visible alert, priority) — this module has zero opinion about any of it. `body` is the full JSON
 * object POSTed to APNs (the `aps` dict plus whatever custom top-level keys the caller wants); this
 * file only stamps the headers Apple requires for HTTP/2 provider push and performs the send.
 */
export interface ApnsRequestSpec {
  /** "background" for a silent/content-available push, "alert" for a visible one. */
  pushType: "background" | "alert";
  /** Apple requires priority "5" for any "background" push-type; "10" is used for user-visible
   * alerts that should be delivered immediately. Never send "10" with pushType "background" — Apple
   * rejects that combination outright (see send-community-push/index.ts's original comment, carried
   * over verbatim below in sendOnePush). */
  priority: "5" | "10";
  body: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Concurrency cap per batch of APNs requests — "batch politely" per the original spec's own phrasing.
// APNs HTTP/2 connections support many concurrent streams, but capping invocation-side concurrency
// avoids hammering both APNs and this function's own outbound connection pool in one burst. Callers may
// override per-invocation via sendInChunks' chunkSize parameter; this is just the shared default.
export const CHUNK_SIZE = 25;

// APNs provider JWTs are valid for up to 60 minutes; Apple's guidance is to reuse one instead of
// re-signing per request. Cached at module scope (survives across invocations on a warm Edge Function
// instance) and refreshed with margin before the true 60-minute ceiling.
export const APNS_JWT_TTL_SECONDS = 55 * 60;

export const APNS_HOSTS: Record<ApnsEnv, string> = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

// ---------------------------------------------------------------------------
// Module-scope JWT cache (per warm instance — best-effort, not shared across cold starts)
// ---------------------------------------------------------------------------
//
// NOTE: this cache is per-DEPLOYED-FUNCTION-INSTANCE, not shared across send-community-push and
// send-regular-push even though both now import this module — each Edge Function is its own Deno
// isolate/deployment with its own module scope. Both functions sign their own JWT on their own first
// invocation and cache it independently; this is unchanged from today (send-community-push already
// only ever cached for itself) and is not a behavior this extraction needed to preserve, since there
// was never cross-function sharing to begin with.

let cachedJwt: string | null = null;
let cachedJwtIssuedAt = 0;
let cachedSigningKey: CryptoKey | null = null;

// ---------------------------------------------------------------------------
// Base64url helpers (Deno has no `Buffer`; Web Crypto + atob/btoa only)
// ---------------------------------------------------------------------------

function base64UrlEncodeBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlEncodeString(str: string): string {
  return base64UrlEncodeBytes(new TextEncoder().encode(str));
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

// ---------------------------------------------------------------------------
// APNs provider-token (JWT, ES256) signing
// ---------------------------------------------------------------------------

async function getSigningKey(privateKeyPem: string): Promise<CryptoKey> {
  if (cachedSigningKey) return cachedSigningKey;
  const keyBuffer = pemToArrayBuffer(privateKeyPem);
  cachedSigningKey = await crypto.subtle.importKey(
    "pkcs8",
    keyBuffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  return cachedSigningKey;
}

export async function getApnsJwt(
  keyId: string,
  teamId: string,
  privateKeyPem: string
): Promise<string> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (cachedJwt && nowSeconds - cachedJwtIssuedAt < APNS_JWT_TTL_SECONDS) {
    return cachedJwt;
  }

  const header = { alg: "ES256", kid: keyId };
  const payload = { iss: teamId, iat: nowSeconds };
  const signingInput = `${base64UrlEncodeString(JSON.stringify(header))}.${base64UrlEncodeString(
    JSON.stringify(payload)
  )}`;

  const key = await getSigningKey(privateKeyPem);
  // Web Crypto's ECDSA sign() returns the raw (r || s) IEEE P1363 signature format, which is exactly
  // what JOSE/JWT ES256 expects — no ASN.1 DER re-encoding needed, unlike most other ECDSA libraries.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  );

  const jwt = `${signingInput}.${base64UrlEncodeBytes(new Uint8Array(signature))}`;
  cachedJwt = jwt;
  cachedJwtIssuedAt = nowSeconds;
  return jwt;
}

// ---------------------------------------------------------------------------
// APNs send
// ---------------------------------------------------------------------------

export async function sendOnePush(
  token: DeviceTokenRow,
  host: string,
  jwt: string,
  topic: string,
  spec: ApnsRequestSpec
): Promise<PushOutcome> {
  try {
    const resp = await fetch(`${host}/3/device/${token.apns_token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": topic,
        // Background/silent pushes MUST use push-type "background" and priority 5 (never 10) —
        // Apple rejects priority-10 background pushes outright. Visible alerts use "alert"/"10" for
        // immediate delivery. The caller (not this shared module) decides which shape applies.
        "apns-push-type": spec.pushType,
        "apns-priority": spec.priority,
        "apns-expiration": "0", // don't store-and-retry a stale relevance signal
        "content-type": "application/json",
      },
      body: JSON.stringify(spec.body),
    });

    if (resp.ok) {
      return { tokenId: token.id, status: resp.status, ok: true, deleted: false };
    }

    let reason: string | undefined;
    try {
      const errBody = (await resp.json()) as { reason?: string };
      reason = errBody?.reason;
    } catch {
      // non-JSON error body — leave reason undefined
    }

    const isDeadToken = resp.status === 410 || (resp.status === 400 && reason === "BadDeviceToken");
    if (isDeadToken) {
      return {
        tokenId: token.id,
        status: resp.status,
        ok: false,
        deleted: true,
        error: reason ?? `HTTP ${resp.status}`,
      };
    }

    return {
      tokenId: token.id,
      status: resp.status,
      ok: false,
      deleted: false,
      error: reason ?? `HTTP ${resp.status}`,
    };
  } catch (err) {
    return { tokenId: token.id, status: null, ok: false, deleted: false, error: String(err) };
  }
}

export async function sendInChunks(
  tokens: DeviceTokenRow[],
  host: string,
  jwt: string,
  topic: string,
  spec: ApnsRequestSpec,
  chunkSize: number = CHUNK_SIZE
): Promise<PushOutcome[]> {
  const outcomes: PushOutcome[] = [];
  for (let i = 0; i < tokens.length; i += chunkSize) {
    const chunk = tokens.slice(i, i + chunkSize);
    const chunkOutcomes = await Promise.all(
      chunk.map((t) => sendOnePush(t, host, jwt, topic, spec))
    );
    outcomes.push(...chunkOutcomes);
  }
  return outcomes;
}
