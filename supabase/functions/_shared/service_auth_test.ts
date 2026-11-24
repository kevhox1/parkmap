// Offline tests. Run:  deno test supabase/functions/_shared/service_auth_test.ts
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { isServiceRoleRequest, projectRefFromUrl, requireServiceRole } from "./service_auth.ts";

const URL_ = "https://jiispshyqerscdoferaw.supabase.co";
const b64u = (o: unknown) =>
  btoa(JSON.stringify(o)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
// Fake, UNSIGNED JWT: the helper never verifies signatures (the gateway does).
const jwt = (payload: unknown) => `${b64u({ alg: "HS256", typ: "JWT" })}.${b64u(payload)}.sig`;
const SERVICE = jwt({ iss: "supabase", ref: "jiispshyqerscdoferaw", role: "service_role", exp: 4102444800 });
const ANON = jwt({ iss: "supabase", ref: "jiispshyqerscdoferaw", role: "anon", exp: 4102444800 });
const ENVKEY = "sb_secret_AbCdEf123"; // runtime key differs from the Vault JWT (the prod finding)
const req = (auth?: string) =>
  new Request("https://x.test/f", { method: "POST", headers: auth ? { Authorization: auth } : {} });

Deno.test("service_role JWT accepted even when env key differs (prod Vault vs runtime key)", () => {
  assertEquals(requireServiceRole(req(`Bearer ${SERVICE}`), ENVKEY, URL_), null);
});

Deno.test("service_role JWT accepted with no ref/iss claims and with empty env key", () => {
  const t = jwt({ role: "service_role" });
  assertEquals(requireServiceRole(req(`Bearer ${t}`), "", URL_), null);
});

Deno.test("anon JWT rejected", async () => {
  const r = requireServiceRole(req(`Bearer ${ANON}`), ENVKEY, URL_);
  assert(r !== null);
  assertEquals(r.status, 401);
  assertEquals(await r.json(), { error: "unauthorized" });
});

Deno.test("service_role JWT for a different project ref or odd iss rejected", () => {
  assertFalse(isServiceRoleRequest(req(`Bearer ${jwt({ role: "service_role", ref: "otherproject" })}`).headers, ENVKEY, URL_));
  assertFalse(isServiceRoleRequest(req(`Bearer ${jwt({ role: "service_role", iss: "evil" })}`).headers, ENVKEY, URL_));
});

Deno.test("exact env key match accepted (opaque sb_secret_ key)", () => {
  assertEquals(requireServiceRole(req(`Bearer ${ENVKEY}`), ENVKEY, URL_), null);
});

Deno.test("empty env key never matches", () => {
  assertFalse(isServiceRoleRequest(req("Bearer x").headers, "", URL_));
  assertFalse(isServiceRoleRequest(req("Bearer ").headers, "", URL_));
});

Deno.test("missing, malformed and garbage bearers get a uniform 401", async () => {
  const bad = [
    undefined, "Bearer", "Bearer ", "Basic abc", "Bearer garbage", "Bearer a.b.c", "Bearer a.b", `Bearer ${ENVKEY}x`,
    `Bearer ${ENVKEY.slice(0, -1)}`, `Bearer ${b64u({})}.${b64u("service_role")}.s`, `Bearer x.${b64u([1])}.s`,
    `Bearer x.!!!notbase64.s`, `Bearer ${jwt({ role: ["service_role"] })}`,
  ];
  for (const a of bad) {
    const r = requireServiceRole(req(a), ENVKEY, URL_);
    assert(r !== null, `should reject ${a}`);
    assertEquals(r!.status, 401);
    assertEquals(await r!.json(), { error: "unauthorized" });
  }
});

Deno.test("projectRefFromUrl", () => {
  assertEquals(projectRefFromUrl(URL_), "jiispshyqerscdoferaw");
  assertEquals(projectRefFromUrl("nonsense"), null);
  assertEquals(projectRefFromUrl(undefined), null);
});
