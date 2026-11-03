import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { signSession, verifySession } from "../src/jwt.js";

const S = "x".repeat(40);

test("sign + verify round trip carries Supabase-compatible claims", () => {
  const { token, exp } = signSession({ sub: "InterQL", appRole: "carrier", trucks: ["3", "4"] }, S, 600);
  const p = verifySession(token, S);
  assert.equal(p.sub, "InterQL");
  assert.equal(p.app_role, "carrier");
  assert.equal(p.role, "authenticated");
  assert.equal(p.aud, "authenticated");
  assert.deepEqual(p.trucks, ["3", "4"]);
  assert.equal(p.exp, exp);
  assert.equal(p.exp - p.iat, 600);
});

test("rejects wrong secret, tampered payload, expiry, alg none, garbage", () => {
  const { token } = signSession({ sub: "a", appRole: "carrier", trucks: [] }, S, 60, 1_000_000);
  assert.equal(verifySession(token, "y".repeat(40), 1_000_000), null);
  assert.equal(verifySession(token, S, 1_000_000 + 61_000), null, "expired");
  const [h, p, s] = token.split(".");
  const evil = Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(p, "base64url")), app_role: "superuser" })).toString("base64url");
  assert.equal(verifySession([h, evil, s].join("."), S, 1_000_000), null, "payload tampered");
  const none = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
  assert.equal(verifySession([none, p, ""].join("."), S, 1_000_000), null, "alg none");
  const hs512 = Buffer.from(JSON.stringify({ alg: "HS512", typ: "JWT" })).toString("base64url");
  const sig = createHmac("sha256", S).update(hs512 + "." + p).digest("base64url");
  assert.equal(verifySession([hs512, p, sig].join("."), S, 1_000_000), null, "other alg");
  assert.equal(verifySession("nope", S), null);
  assert.equal(verifySession(undefined, S), null);
});
