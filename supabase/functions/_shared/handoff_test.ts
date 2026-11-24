// Offline unit tests for the Spot Pass shared helpers. Run:  deno test supabase/functions/_shared/handoff_test.ts
// (No network, no Supabase: only the pure modules handoff.ts and handoff_push.ts are imported.)
import { assert, assertEquals, assertFalse, assertNotEquals } from "jsr:@std/assert@1";
import {
  allowedOrigins,
  allowedTopics,
  bearer,
  clientIp,
  controlFlagResponse,
  corsHeaders,
  envKillSwitch,
  ipHash,
  isDepartSource,
  isSecret,
  isToken,
  isUuid,
  parseClaimBody,
  readJsonBody,
  safeEqual,
} from "./handoff.ts";
import {
  approxMinutes,
  driverThanksAlertBody,
  HandoffPushRow,
  isClipTopic,
  liveActivityEndBody,
  liveActivityTopic,
  seekerAlertBody,
  silentEndedBody,
  stateAllows,
} from "./handoff_push.ts";

const TOKEN = "AbCdEfGhIjKlMnOpQrStUv"; // 22 chars
const TOPICS = allowedTopics("com.kevinhoxha.wepark", null);

Deno.test("token / secret / uuid / source validation", () => {
  assert(isToken(TOKEN));
  assert(isSecret(TOKEN));
  assertFalse(isToken("short"));
  assertFalse(isToken(TOKEN + "A"));
  assertFalse(isToken("AbCdEfGhIjKlMnOpQrSt+/")); // not base64url
  assertFalse(isToken(null));
  assert(isUuid("123e4567-e89b-12d3-a456-426614174000"));
  assertFalse(isUuid("123e4567"));
  for (const s of ["manual", "live_activity", "notification", "auto", "start_driving", "shortcut"]) assert(isDepartSource(s));
  assertFalse(isDepartSource("teleport"));
});

Deno.test("claim body: normalizes, validates, restricts topics", () => {
  const ok = parseClaimBody({ token: TOKEN, leave_at: "2026-11-24T10:07:00-05:00" }, TOPICS, "com.kevinhoxha.wepark");
  assert(ok.ok);
  if (ok.ok) {
    assertEquals(ok.value.leaveAt, "2026-11-24T15:07:00.000Z");
    assertEquals(ok.value.topic, null); // no tokens => no topic stored
  }
  const tok = "a".repeat(64);
  const withPush = parseClaimBody({ token: TOKEN, leave_at: new Date().toISOString(), push_token: tok }, TOPICS, "com.kevinhoxha.wepark");
  assert(withPush.ok && withPush.value.topic === "com.kevinhoxha.wepark"); // defaults to the app topic
  const clip = parseClaimBody(
    { token: TOKEN, leave_at: new Date().toISOString(), push_token: tok, activity_token: "b".repeat(100), topic: "com.kevinhoxha.wepark.Clip" },
    TOPICS,
    "com.kevinhoxha.wepark",
  );
  assert(clip.ok && clip.value.topic === "com.kevinhoxha.wepark.Clip");
  const evil = parseClaimBody({ token: TOKEN, leave_at: new Date().toISOString(), push_token: tok, topic: "com.evil.app" }, TOPICS, null);
  assertFalse(evil.ok);
  const badTok = parseClaimBody({ token: "nope", leave_at: new Date().toISOString() }, TOPICS, null);
  assert(!badTok.ok && badTok.reason === "bad_token_format");
  const badTime = parseClaimBody({ token: TOKEN, leave_at: "tomorrow-ish" }, TOPICS, null);
  assert(!badTime.ok && badTime.reason === "invalid_leave_at");
  const badPush = parseClaimBody({ token: TOKEN, leave_at: new Date().toISOString(), push_token: "xyz" }, TOPICS, null);
  assertFalse(badPush.ok);
  assertFalse(parseClaimBody(null, TOPICS, null).ok);
});

Deno.test("allowed topics include the clip; extras merge without duplicates", () => {
  assertEquals(allowedTopics("a.b", null), ["a.b", "a.b.Clip"]);
  assertEquals(allowedTopics("a.b", "x.y, a.b ,z"), ["a.b", "a.b.Clip", "x.y", "z"]);
  assertEquals(allowedTopics(null, null), []);
});

Deno.test("kill switch only trips on explicit off values", () => {
  for (const v of ["false", "FALSE", "0", "off", "no"]) assert(envKillSwitch(v));
  for (const v of ["true", "", null, undefined, "1"]) assertFalse(envKillSwitch(v));
});

Deno.test("CORS: only listed origins get headers", () => {
  const allowed = allowedOrigins("https://getwepark.com, https://kevhox1.github.io");
  assertEquals(allowed.length, 2);
  assertEquals(corsHeaders("https://getwepark.com", allowed)["Access-Control-Allow-Origin"], "https://getwepark.com");
  assertEquals(corsHeaders("https://evil.example", allowed)["Access-Control-Allow-Origin"], undefined);
  assertEquals(corsHeaders(null, allowed)["Access-Control-Allow-Origin"], undefined);
  assertEquals(allowedOrigins(undefined), ["https://getwepark.com"]);
});

Deno.test("ip hashing: stable, salted, never contains the IP", async () => {
  const a = await ipHash("203.0.113.9", "salt1");
  assertEquals(a, await ipHash("203.0.113.9", "salt1"));
  assertNotEquals(a, await ipHash("203.0.113.9", "salt2"));
  assertNotEquals(a, await ipHash("203.0.113.10", "salt1"));
  assertEquals(a.length, 32);
  assertFalse(a.includes("203"));
});

Deno.test("client ip + bearer parsing", () => {
  // forged leading XFF hop is ignored: last hop (appended by the trusted proxy) wins
  assertEquals(clientIp(new Headers({ "x-forwarded-for": "6.6.6.6, 203.0.113.9" })), "203.0.113.9");
  assertEquals(clientIp(new Headers({ "x-forwarded-for": "203.0.113.9" })), "203.0.113.9");
  // cf-connecting-ip beats any x-forwarded-for
  assertEquals(clientIp(new Headers({ "cf-connecting-ip": "5.6.7.8", "x-forwarded-for": "6.6.6.6" })), "5.6.7.8");
  assertEquals(clientIp(new Headers({ "cf-connecting-ip": "5.6.7.8" })), "5.6.7.8");
  assertEquals(clientIp(new Headers()), "unknown");
  assertEquals(bearer(new Headers({ authorization: "Bearer abc.def" })), "abc.def");
  assertEquals(bearer(new Headers({ authorization: "Basic xyz" })), null);
  assertEquals(bearer(new Headers()), null);
  assert(safeEqual("k", "k"));
  assertFalse(safeEqual("k", "kk"));
  assertFalse(safeEqual("a", "b"));
});

Deno.test("control flags map to HTTP: disabled=503, rate_limited=429 with the endpoint's own denied body", async () => {
  const d = controlFlagResponse({ disabled: true }, { status: "unavailable" }, {});
  assertEquals(d?.status, 503);
  assertEquals(await d?.json(), { error: "disabled" });
  const r = controlFlagResponse({ rate_limited: true }, { ok: false }, {});
  assertEquals(r?.status, 429);
  assertEquals(await r?.json(), { ok: false });
  assertEquals(controlFlagResponse({ ok: true }, { ok: false }, {}), null);
});

const row = (over: Partial<HandoffPushRow> = {}): HandoffPushRow => ({
  id: "123e4567-e89b-12d3-a456-426614174000",
  status: "armed",
  seeker_id: "seeker",
  alias: "Bodega Cat",
  seeker_display_name: null,
  leave_at: new Date(Date.now() + 31 * 60000).toISOString(),
  outcome: null,
  claimer_push_token: null,
  claimer_activity_token: null,
  claimer_topic: null,
  ...over,
});

Deno.test("push state gates", () => {
  assert(stateAllows("armed", row()));
  assertFalse(stateAllows("armed", row({ status: "created" })));
  assert(stateAllows("departed", row({ status: "departed" })));
  assert(stateAllows("thanks", row({ status: "departed", outcome: "got_spot" })));
  assertFalse(stateAllows("thanks", row({ status: "departed", outcome: "no_luck" }))); // thanks is positive-only
  assertFalse(stateAllows("thanks", row({ status: "departed", outcome: null })));
  assert(stateAllows("handoff_ended", row({ status: "cancelled" })));
  assert(stateAllows("handoff_ended", row({ status: "suspended" })));
  assertFalse(stateAllows("handoff_ended", row({ status: "armed" })));
});

Deno.test("seeker alerts: coarse minutes, never a clock time, never location", () => {
  const now = Date.now();
  assertEquals(approxMinutes(new Date(now + 31 * 60000).toISOString(), now), 30);
  assertEquals(approxMinutes(new Date(now + 3 * 60000).toISOString(), now), null);
  const armed = JSON.stringify(seekerAlertBody("armed", row(), now));
  assert(armed.includes("about 30 min"));
  assertFalse(/\d{1,2}:\d{2}/.test(armed)); // no clock time
  assertFalse(/lat|lng|address|block/i.test(armed));
  const soon = JSON.stringify(seekerAlertBody("armed", row({ leave_at: new Date(now + 60000).toISOString() }), now));
  assert(soon.includes("leaving soon"));
  const dep = seekerAlertBody("departed", row({ status: "departed" }), now) as { aps: { alert: { body: string } }; kind: string };
  assertEquals(dep.aps.alert.body, "Your neighbor is pulling out now.");
  assertEquals(dep.kind, "departed");
});

Deno.test("driver payloads: thanks alert (clip adds target-content-id), silent ended, ActivityKit end", () => {
  const app = driverThanksAlertBody(row(), false, "https://getwepark.com/p") as { aps: Record<string, unknown> };
  assertEquals(app.aps["target-content-id"], undefined);
  const clip = driverThanksAlertBody(row({ seeker_display_name: "Maya" }), true, "https://getwepark.com/p") as {
    aps: { alert: { body: string }; "target-content-id": string };
  };
  assertEquals(clip.aps["target-content-id"], "https://getwepark.com/p");
  assertEquals(clip.aps.alert.body, "Maya got your spot.");
  const silent = silentEndedBody(row()) as { aps: Record<string, unknown> };
  assertEquals(silent.aps, { "content-available": 1 }); // no alert, no sound
  const la = liveActivityEndBody("thanks", row(), 1000) as { aps: Record<string, unknown> };
  assertEquals(la.aps.event, "end");
  assertEquals((la.aps["content-state"] as { phase: string }).phase, "thanks");
  const ended = liveActivityEndBody("handoff_ended", row(), 1000) as { aps: Record<string, unknown> };
  assertEquals(ended.aps["dismissal-date"], 1000);
  assertEquals(ended.aps.alert, undefined);
  assertEquals(liveActivityTopic("com.kevinhoxha.wepark.Clip"), "com.kevinhoxha.wepark.Clip.push-type.liveactivity");
  assert(isClipTopic("com.kevinhoxha.wepark.Clip", "com.kevinhoxha.wepark"));
  assertFalse(isClipTopic("com.kevinhoxha.wepark", "com.kevinhoxha.wepark"));
});

Deno.test("readJsonBody rejects oversized bodies while streaming (no content-length)", async () => {
  const big = new ReadableStream<Uint8Array>({
    start(c) {
      const chunk = new TextEncoder().encode("x".repeat(1024));
      for (let i = 0; i < 8; i++) c.enqueue(chunk);
      c.close();
    },
  });
  const req = new Request("http://x/", { method: "POST", body: big, // @ts-ignore deno duplex
    duplex: "half" });
  assertEquals(await readJsonBody(req), null);
  const ok = new Request("http://x/", { method: "POST", body: JSON.stringify({ a: 1 }) });
  assertEquals(await readJsonBody(ok), { a: 1 });
});
