// Offline tests. Run:  deno test supabase/functions/_shared/service_auth_test.ts
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import { isServiceRoleRequest, requireServiceRole } from "./service_auth.ts";

const KEY = "service-role-key-abc.def.ghi";
const req = (auth?: string) =>
  new Request("https://x.test/f", { method: "POST", headers: auth ? { Authorization: auth } : {} });

Deno.test("accepts the exact service-role bearer", () => {
  assert(isServiceRoleRequest(req(`Bearer ${KEY}`).headers, KEY));
  assertEquals(requireServiceRole(req(`Bearer ${KEY}`), KEY), null);
});

Deno.test("accepts new-style sb_secret_ keys (opaque compare)", () => {
  const k = "sb_secret_AbCdEf123";
  assertEquals(requireServiceRole(req(`Bearer ${k}`), k), null);
});

Deno.test("rejects missing, malformed, anon and near-miss bearers with a uniform 401", async () => {
  const bad = [undefined, "Bearer", "Bearer ", KEY, "Basic abc", `Bearer ${KEY}x`, `Bearer ${KEY.slice(0, -1)}`, "Bearer anon.public.key"];
  for (const a of bad) {
    const r = requireServiceRole(req(a), KEY);
    assert(r !== null, `should reject ${a}`);
    assertEquals(r!.status, 401);
    assertEquals(await r!.json(), { error: "unauthorized" });
  }
});

Deno.test("empty server key never authenticates", () => {
  assertFalse(isServiceRoleRequest(req("Bearer x").headers, ""));
});
